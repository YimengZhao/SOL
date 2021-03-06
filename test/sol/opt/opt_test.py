import pytest
from sol.opt.cplexwrapper import OptimizationCPLEX, InvalidConfigException
from sol.opt.gurobiwrapper import OptimizationGurobi
from sol.topology.provisioning import generateTrafficClasses

from sol.opt import initOptimization, getOptimization
from sol.path.predicates import nullPredicate
from sol.topology import provisioning
from sol.topology.generators import generateCompleteTopology

_backends = ['cplex', 'gurobi']


def test_getFunc():
    opt = getOptimization('cplex')
    assert isinstance(opt, OptimizationCPLEX)
    opt = getOptimization('CPlex')
    assert isinstance(opt, OptimizationCPLEX)
    opt = getOptimization('GuRobi')
    assert isinstance(opt, OptimizationGurobi)

    with pytest.raises(InvalidConfigException):
        opt = getOptimization('fakebackend')


@pytest.mark.parametrize("backend", _backends)
def test_MaxFlow(backend):
    # ==============
    # Fake some data
    # ==============
    topo = generateCompleteTopology(5)
    # ingress-egress pairs
    iePairs = [(0, 3)]
    # generate traffic matrix
    trafficMatrix = provisioning.uniformTM(
        iePairs, 10 ** 6)
    # compute traffic classes, only one class
    trafficClasses = generateTrafficClasses(iePairs, trafficMatrix, {'allTraffic': 1},
                                            {'allTraffic': 2000})
    linkcaps = provisioning.provisionLinks(topo, trafficClasses, 1)
    # do not load links more than 50%
    linkConstrCaps = {(u, v): 1 for u, v in topo.links()}

    # ==============
    # Optimize
    # ==============
    linkcapfunc = lambda link, tc, path, resource: tc.volBytes / linkcaps[link]
    # Start our optimization! SOL automatically takes care of the paths behind the scenes
    opt, pptc = initOptimization(topo, trafficClasses, nullPredicate, 'shortest', 5, backend=backend)
    # Traffic must flow!
    opt.allocateFlow(pptc)
    # Traffic must not overload links!
    opt.capLinks(pptc, 'bandwidth', linkConstrCaps, linkcapfunc)
    # Push as much traffic as we can!
    opt.maxFlow(pptc)
    opt.solve()

    for tc, paths in opt.getPathFractions(pptc).iteritems():
        for p in paths:
            print p
            assert len(p) == 2

    assert opt.getSolvedObjective() == 1
