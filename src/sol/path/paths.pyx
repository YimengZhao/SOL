# coding=utf-8
import random
import warnings

from sol.utils.pythonHelper import listEq
from paths cimport Path
from paths cimport PathWithMbox
from sol.topology.topology cimport Topology

cdef class Path:
    """ Represents a path in the network"""

    def __init__(self, nodes, ID=-1, flowFraction=0):
        """Create a new path

        :param nodes: a list of node ids that belong to a path
        :param flowFraction: the number of flows on this path
        """
        self._nodes = list(nodes)
        self._flowFraction = flowFraction
        self._ID = ID
        if self._ID == -1:
            self._ID = random.randint(0, 1e6)
            warnings.warn('No ID given to Path constructor, generating a random path ID')
        self._links = self._computeLinks()

    @staticmethod
    def decode(dict dictionary):
        """
        Create a new path from a dict
        :param dictionary: dict type, must contain following keys:

            'nodes': maps to a list of nodes
        """
        return Path(dictionary['nodes'], dictionary.get('numFlows', 0))

    cpdef int getIngress(self):
        """
        :return: the ingress node of this path
        """
        return self._nodes[0]

    cdef _computeLinks(self):
        return zip(self._nodes, self._nodes[1:])

    cpdef int getEgress(self):
        """
        :return: the egress node of this path
        """
        return self._nodes[-1]

    cpdef getNodes(self):
        """
        :return: all nodes as a list
        """
        return self._nodes

    # cpdef getNodesAsTuple(self):
    #     """
    #     :return: all nodes in this path as a tuple
    #     """
    #     return tuple(self._nodes)

    cpdef tuple getIEPair(self):
        """
        :return: ingress-egress pair for this path
        :rtype: tuple
        """
        return self.getIngress(), self.getEgress()

    cpdef double getFlowFraction(self):
        """
        :return: the number of flows on this path.
        """
        return self._flowFraction

    cpdef setFlowFraction(self, double nflows):
        """
        Set number of flows on this path

        :param nflows: the new number of flows
        """
        self._flowFraction = nflows

    cpdef getLinks(self):
        """
        :return: Return an iterator over the links in this path
        """
        # return zip(self._nodes, self._nodes[1:])
        return self._links

    cpdef int getID(self):
        return self._ID

    def encode(self):
        """
        Encode this path in dict/list form so it can be JSON-ed or MsgPack-ed

        :return: dictionary representation of this path
        """
        return {'nodes': self._nodes, 'numFlows': self._flowFraction}

    def __contains__(self, item):
        return item in self._nodes

    def __getitem__(self, item):
        return self._nodes[item]

    def __hash__(self):
        # TODO: implement a better universal hash function that computes based on _nodes
        return self.getID()

    # def __setitem__(self, key, value):
    #     self._nodes[key] = value

    def __getslice__(self, int i, int j):
        return self._nodes[i:j]

    def __iter__(self):
        return self._nodes.__iter__()

    def __len__(self):
        return len(self._nodes)

    def __repr__(self):
        return "Path(nodes={}, numFlows={})".format(str(self._nodes),
                                                    self._flowFraction)

    # noinspection PyProtectedMember
    def __richcmp__(Path self, other not None, int op):
        sameType = isinstance(other, Path)
        if op == 2:
            return sameType and listEq(self._nodes, other._nodes)
        elif op == 3:
            return not sameType or not listEq(self._nodes, other._nodes)
        else:
            raise TypeError

    def __copy__(self):
        return Path(self._nodes, self._ID, self._flowFraction)

cdef class PathWithMbox(Path):
    """
    Create a new path with middleboxes

    :param nodes: path nodes (an ordered list)
    :param useMBoxes: at which nodes the middleboxes will be used
    :param numFlows: number of flows (if any) along this path. Default is 0.
    """

    def __init__(self, nodes, useMBoxes, int ind=0, flowFraction=0):
        super(PathWithMbox, self).__init__(nodes, ind, flowFraction)
        self.useMBoxes = list(useMBoxes)

    @staticmethod
    def decode(dict dictionary):
        """
        Create a new path from a dict
        :param dictionary: dict type, must contain following keys:

            'nodes': maps to a list of nodes
            'useMBoxes': maps to a list of nodes at which middlebox is used
        """
        return PathWithMbox(dictionary['nodes'], dictionary['useMBoxes'], dictionary.get('numFlows', 0))

    def usesBox(self, node):
        """
        Check the path uses a given middlebox

        :param node: nodeID in question
        :return: True or False
        """
        return node in self.useMBoxes

    def fullLength(self):
        """

        :return: The full length of the path (includes all middleboxes)
        """
        return len(self._nodes) + len(self.useMBoxes)

    def encode(self):
        """
        Encode this path in dict/list form so it can be JSON-ed or MsgPack-ed

        :return: dictionary representation of this path
        """
        return {'nodes': self._nodes, 'numFlows': self._flowFraction, 'useMBoxes': self.useMBoxes,
                'PathWithMbox': True}

    # noinspection PyProtectedMember
    def __richcmp__(PathWithMbox self, other not None, int op):
        sameType = isinstance(other, PathWithMbox)
        if op == 2:
            return sameType and listEq(self._nodes, other._nodes) and listEq(self.useMBoxes, other.useMBoxes)
        elif op == 3:
            return not sameType or not listEq(self._nodes, other._nodes) or not listEq(self.useMBoxes, other.useMBoxes)
        else:
            raise TypeError

    def __hash__(self):
        # TODO: implement a better universal hash function that computes based on _nodes + useMBoxes
        return self.getID()


    def __repr__(self):
        return "PathWithMbox(nodes={}, useMBoxes={} numFlows={})". \
            format(str(self._nodes), self.useMBoxes, self._flowFraction)

    def __copy__(self):
        return PathWithMbox(self._nodes, self.useMBoxes, self._ID, self._flowFraction)

cdef double computePathCapacity(Path p, str resourceName, Topology topo):
    b = []
    for x in p.getNodes() + p.getLinks():
        res = topo.getResources(x)
        if resourceName in res:
            b.append(res[x])
    return min(b)
