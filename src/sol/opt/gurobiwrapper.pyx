# coding=utf-8
from __future__ import division, print_function

import copy
from collections import defaultdict

from six import iterkeys, itervalues
from six.moves import range

from varnames import *
from ..utils.exceptions import SOLException

try:
    from gurobipy import *
except ImportError as e:
    print("Cannot use Gurobi Python API. Please install Gurobi and gurobipy")
    raise e


class OptimizationGurobi(object):
    def __init__(self):
        self.opt = Model()
        self.intvars = set()

    def addDecisionVars(self, pptc):
        for tc in pptc:
            for path in pptc[tc]:
                name = xp(tc, path)
                self.opt.addVar(lb=0, ub=1, name=name)
        self.opt.update()

    def addBinaryVars(self, pptc, topology, types):
        cdef int pi
        for t in types:
            if t.lower() == 'node':
                for n in topology.nodes(False):
                    self.opt.addVar(vtype=GRB.BINARY, name=bn(n))
            elif t.lower() == 'edge':
                for u, v in topology.links(False):
                    self.opt.addVar(vtype=GRB.BINARY, name=be(u, v))
            elif t.lower() == 'path':
                for tc in pptc:
                    for pi in range(len(pptc[tc])):
                        self.opt.addVar(vtype=GRB.BINARY, name=bp(tc, pi))
            else:
                raise SOLException("Unknown binary variable type")

    def allocateFlow(self, pptc, allocation=None):
        cdef int pi
        for tc in pptc:
            name = al(tc)
            self.opt.addVar(lb=0, ub=1, name=name)
        self.opt.update()
        if allocation is None:
            for tc in pptc:
                name = al(tc)
                lhs = LinExpr()
                for path in pptc[tc]:
                    lhs.addTerms(1, self.v(xp(tc, path)))
                self.opt.addConstr(lhs == self.v(name), name='Allocation.tc.{}'.format(tc.ID))
        else:
            for tc in pptc:
                name = self.al(tc)
                self.opt.addConstr(self.v(name) == allocation,
                                   name='Allocation.tc.{}'.format(tc.ID))
        self.opt.update()

    def routeAll(self, pptc):
        for tc in pptc:
            name = al(tc)
            v = self.v(name)
            v.lb = v.ub = 1
        self.opt.update()

    def capLinks(self, pptc, resource, linkCaps, linkCapFunc):
        expressions = defaultdict(lambda: LinExpr())
        for tc in pptc:
            for path in pptc[tc]:
                for link in path.getLinks():
                    expressions[link].addTerms(linkCapFunc(link, tc, path, resource),
                                               self.v(xp(tc, path)))
        for link, cap in linkCaps.iteritems():
            name = 'LinkLoad_{}_{}'.format(resource, tup2str(link))
            if self.v(name) is None:
                self.opt.addVar(name=name, ub=cap)
                self.opt.update()
            self.opt.addConstr(expressions[link] == self.v(name),
                               name='LinkCap.{}.{}'.format(resource, tup2str(link)))
        self.opt.update()

    def capNodes(self, pptc, resource, nodeCaps, nodeCapFunc):
        cdef int pi
        expressions = defaultdict(lambda: LinExpr())
        for tc in pptc:
            for pi, path in enumerate(pptc[tc]):
                for node in path.getNodes():
                    expressions[node].addTerms(nodeCapFunc(node, tc, path, resource),
                                               self.v(xp(tc, path)))
        for node, cap in nodeCaps.iteritems():
            name = 'NodeLoad_{}_{}'.format(resource, node)
            if self.v(name) is None:
                self.opt.addVar(name=name, ub=cap)
                self.opt.update()
            self.opt.addConstr(expressions[node] == self.v(name))
        self.opt.update()

    # TODO: consume & capNodes/Links are kind of redundant at this point, clean it up

    def consume(self, pptc, resourceName, cost, nodeCaps, linkCaps):
        """
        :param pptc: paths per traffic class
        :param resource: resource to be consumed
        :param cost: cost per flow for this resource
        """
        expressions = defaultdict(lambda: LinExpr())
        for tc in pptc:
            #TODO: optimize loop
            for path in pptc[tc]:
                v = self.v(xp(tc, path))
                for node in path.getNodes():
                    if node in nodeCaps:
                        expressions[node].addTerms(tc.volFlows * cost / nodeCaps[node], v)
                for link in path.getLinks():
                    if link in linkCaps:
                        expressions[link].addTerms(tc.volFlows * cost / linkCaps[link], v)
        for node in nodeCaps:
            name = 'NodeLoad_{}_{}'.format(resourceName, node)
            if self.v(name) is None:
                self.opt.addVar(name=name, ub=1)
                self.opt.update()
            self.opt.addConstr(expressions[node] == self.v(name), name='NodeLoad.{}.{}'.format(
                resourceName, node))
        for link in linkCaps:
            name = 'LinkLoad_{}_{}'.format(resourceName, tup2str(link))
            if self.v(name) is None:
                self.opt.addVar(name=name, ub=1)
                self.opt.update()
            self.opt.addConstr(expressions[link] == self.v(name), name='LinkLoad.{}.{}'.format(
                resourceName, tup2str(link)))
        self.opt.update()

    def _reqAll(self, pptc, trafficClasses=None, reqType=None):
        if reqType is None:
            raise SOLException('A type of constraint is needed for reqAll()')
        cdef int pi
        if trafficClasses is None:
            trafficClasses = pptc.keys()
        if reqType.lower() == 'node':
            for tc in trafficClasses:
                for pi, path in enumerate(pptc[tc]):
                    for n in path:
                        self.opt.addConstr(self.v(bp(tc, pi)) <= self.v(bn(n)))
        elif reqType.lower() == 'edge' or reqType.lower == 'link':
            for tc in trafficClasses:
                for pi, path in enumerate(pptc[tc]):
                    # TODO: see if this can be optimized
                    for link in path.getLinks():
                        self.opt.addConstr(self.v(bp(tc, pi)) <= self.v(be(*link)))
        else:
            raise SOLException('Unknown type of constraint for reqAll()')
        self.opt.update()

    def _reqSome(self, pptc, trafficClasses=None, reqType=None):
        if reqType is None:
            raise SOLException('A type of constraint is needed for reqSome()')
        cdef int pi
        if trafficClasses is None:
            trafficClasses = pptc.keys()
        if reqType.lower() == 'node':
            for tc in trafficClasses:
                for pi, path in enumerate(pptc[tc]):
                    expr = LinExpr()
                    for n in path:
                        expr.add(self.v(bn(n)))
                    self.opt.addConstr(self.v(bp(tc, pi)) <= expr)
        elif reqType.lower() == 'edge' or reqType.lower == 'link':
            for tc in trafficClasses:
                for pi, path in enumerate(pptc[tc]):
                    expr = LinExpr()
                    # TODO: see if this can be optimized
                    for link in path.getLinks():
                        expr.add(self.v(be(*link)))
                    self.opt.addConstr(self.v(bp(tc, pi)) <= expr)
        else:
            raise SOLException('Unknown type of constraint for reqSome()')
        self.opt.update()

    def reqAllNodes(self, pptc, trafficClasses=None):
        return self.reqAll(pptc, trafficClasses, 'node')

    def reqAllLinks(self, pptc, trafficClasses=None):
        return self._reqAll(pptc, trafficClasses, 'link')

    def reqSomeNodes(self, pptc, trafficClasses=None):
        return self._reqSome(pptc, trafficClasses, 'node')

    def reqSomeLinks(self, pptc, trafficClasses=None):
        return self._reqSome(pptc, trafficClasses, 'link')

    def disablePaths(self, pptc, trafficClasses=None):
        if trafficClasses is None:
            trafficClasses = pptc.keys()
        cdef int pi
        for tc in trafficClasses:
            for pi, path in enumerate(bp(tc, pi)):
                self.opt.addConstr(self.v(xp(tc, path)) <= self.v(bp(tc, pi)))
        self.opt.update()

    def enforceSinglePath(self, pptc, trafficClasses):
        if trafficClasses is None:
            trafficClasses = iterkeys(pptc)
        cdef int pi
        for tc in trafficClasses:
            for pi, path in enumerate(pptc[tc]):
                self.opt.addConstr(self.v(bp(tc, pi)))
        self.opt.update()

    def minLatency(self, topo, pptc, weight=1.0, norm=True):
        latency = self.opt.addVar(name="Latency", obj=weight)
        self.opt.update()
        latencyExpr = LinExpr()
        normFactor = 1.0
        if norm:
            normFactor = sum(map(len, [paths for paths in itervalues(pptc)]))
        for tc in pptc:
            for pi, path in enumerate(pptc[tc]):
                latencyExpr.addTerms(len(path) / normFactor, self.v(xp(tc, path)))
        self.opt.addConstr(latency == latencyExpr)
        self.opt.update()
        return latency

    def nodeBudget(self, topology, budgetFunc, bound):
        g = topology.getGraph()
        expr = LinExpr()
        for n in topology.nodes(data=False):
            expr.add(self.v(bn(n)), budgetFunc(n))
        self.opt.addConstr(expr <= bound)
        self.opt.update()

    # TODO: mindiff
    # TODO: externalize strings
    # TODO: single path constraint

    def _minLoad(self, resource, prefix, float weight):
        objName = 'Max{}_{}'.format(prefix, resource)
        obj = self.opt.addVar(name=objName, obj=weight)
        self.opt.update()
        prefix = '{}_{}'.format(prefix, resource)
        for var in self.opt.getVars():
            if var.VarName.startswith(prefix):
                self.opt.addConstr(obj >= var)
        self.opt.update()
        return obj

    def minNodeLoad(self, resource, float weight=1.0):
        return self._minLoad(resource, 'NodeLoad', weight)

    def minLinkLoad(self, resource, float weight=1.0):
        return self._minLoad(resource, 'LinkLoad', weight)

    def maxFlow(self, pptc, weight=1.0):
        objName = MAX_ALL_FLOW
        obj = self.opt.addVar(name=objName, obj=weight)
        self.opt.update()
        self.opt.addConstr(obj == 1-quicksum([self.v(al(tc)) for tc in pptc]))
        self.opt.ModelSense = GRB.MAXIMIZE
        self.opt.update()

    def getMaxLinkLoad(self, resource, value=True):
        v = self.v("MaxLinkLoad_{}".format(resource))
        return v.x if value else v

    def getLatency(self, value=True):
        v = self.v("Latency")
        return v.x if value else v

    def relaxToLP(self):
        for v in self.opt.getVars():
            if v.vType == GRB.BINARY:
                self.intvars.add(v)
                v.vType = GRB.CONTINUOUS
        self.opt.update()

    def setTimeLimit(self, long time):
        self.opt.params.TimeLimit = time
        self.opt.update()

    def solve(self):
        self.opt.optimize()

    def write(self, fname):
        self.opt.write(fname + ".lp")

    def writeSolution(self, fname):
        self.write(fname + ".sol")

    def getGurobiModel(self):
        return self.opt

    def getVarValues(self):
        return {var.VarName: var.x for var in self.opt.getVars()}

    def getVar(self, name):
        return self.opt.getVarByName(name)

    def copy(self):
        c = OptimizationGurobi()
        c.opt = self.opt.copy()
        return c

    def save(self, fname):
        pass

    def getSolvedObjective(self):
        return self.opt.ObjVal

    def isSolved(self):
        return self.opt.Status == GRB.OPTIMAL

    def v(self, n):
        return self.opt.getVarByName(n)

    def getPathFractions(self, pptc, flowCarryingOnly=True):
        result = {}
        for tc, paths in pptc.iteritems():
            result[tc] = []
            for path in paths:
                newpath = copy.copy(path)
                newpath.setFlowFraction(self.opt.getVarByName(xp(tc, path)).x)
                if newpath.getFlowFraction() > 0 and flowCarryingOnly:
                    result[tc].append(newpath)
                elif not flowCarryingOnly:
                    result[tc].append(newpath)
        return result

