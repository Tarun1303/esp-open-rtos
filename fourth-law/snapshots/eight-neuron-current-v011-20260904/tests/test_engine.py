import math
import unittest

from engine import PhysicsNetwork


class PhysicsNetworkTests(unittest.TestCase):
    def make_network(self, seed=3):
        net = PhysicsNetwork(seed=seed, background_rate=0.0)
        net.background_power = 0.0
        net.external_quantum = 1.20
        net.max_discharge = 1.40
        return net

    def test_graph_degree_sequence(self):
        net = self.make_network()
        self.assertEqual([len(v) for v in net.outgoing], [4, 4, 3, 3, 2, 2, 3, 3])

    def test_resistance_is_derived_from_geometry(self):
        net = self.make_network()
        edge = net.directed_edges[0]
        expected = net.resistivity * edge.length / edge.area
        self.assertAlmostEqual(net.resistance(edge), expected, places=12)
        old_resistance = net.resistance(edge)
        edge.area *= 1.1
        self.assertAlmostEqual(net.resistance(edge), old_resistance / 1.1, places=12)

    def test_discharge_does_not_multiply_energy(self):
        net = self.make_network()
        net.energy[0] = 1.35
        before_dissipated = net.total_dissipated_energy
        net._fire(0)
        scheduled_received = sum(item[2] for item in net.arrivals)
        released = min(net.max_discharge, 1.35 - net.reset_energy)
        dissipated = net.total_dissipated_energy - before_dissipated
        self.assertLessEqual(scheduled_received, released + 1e-12)
        self.assertAlmostEqual(scheduled_received + dissipated, released, places=10)

    def test_training_changes_structure_but_preserves_material_budget(self):
        net = self.make_network()
        before = [edge.area for edge in net.directed_edges]
        for _ in range(20):
            net.clear_dynamic_state()
            net.conditioning_cycle("1+1", "2")
        after = [edge.area for edge in net.directed_edges]
        self.assertGreater(max(abs(a - b) for a, b in zip(after, before)), 0.05)
        for source, indices in enumerate(net.outgoing):
            self.assertAlmostEqual(sum(net.directed_edges[k].area for k in indices), net.material_budget[source], places=8)

    def test_one_plus_one_association_is_recalled_after_conditioning(self):
        net = self.make_network(seed=3)
        before = net.recall_once("1+1")
        self.assertNotEqual(before["predicted"], "2")
        for _ in range(100):
            net.clear_dynamic_state()
            net.conditioning_cycle("1+1", "2")
        after = net.recall_once("1+1")
        self.assertEqual(after["predicted"], "2")
        self.assertGreater(after["scores"]["2"], after["scores"]["1"])

    def test_background_drive_produces_multiple_spiking_nodes(self):
        net = PhysicsNetwork(seed=5, background_rate=3.0)
        net.run_for(20.0)
        fired = {i for _, i in net.spike_history}
        self.assertGreaterEqual(len(net.spike_history), 20)
        self.assertGreaterEqual(len(fired), 4)


if __name__ == "__main__":
    unittest.main(verbosity=2)
