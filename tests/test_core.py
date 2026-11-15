import copy
import json
import socket
import tempfile
import unittest

from control24 import osc, protocol
from control24.engine import Engine


class ProtocolTests(unittest.TestCase):
    def test_running_status_faders_and_buttons_in_one_frame(self):
        packet = protocol.frame([bytes.fromhex('90 10 5c 0f 1c b0 00 7f 20 7f 40 3f')])
        events = protocol.Decoder().decode(packet)
        self.assertEqual([(e['control'], e['value']) for e in events],
                         [('button:28:16', True), ('button:28:15', False),
                          ('fader:0', 16383), ('encoder:0', -1)])

    def test_lsb_without_msb_does_not_invent_a_position(self):
        events = protocol.Decoder().decode(protocol.frame([b'\xb0\x20\x7f']))
        self.assertEqual(events[0]['kind'], 'unknown')

    def test_truncated_and_invalid_frames(self):
        for packet in (b'', b'\0'*15, b'\0'*16,
                       protocol.frame([b'\xb0\x00']), protocol.frame([b'\xf0\x13'])):
            with self.assertRaises(ValueError):
                protocol.Decoder().decode(packet)

    def test_realtime_inside_running_status(self):
        events = protocol.Decoder().decode(protocol.frame([bytes.fromhex('b0 00 f8 40 20 01')]))
        self.assertEqual(events[0]['value'], 8193)

    def test_motor_roundtrip_and_frame_padding(self):
        for ch in (0, 7, 8, 23):
            for value in (0, 127, 128, 8192, 16383):
                packet = protocol.frame([protocol.fader_motor(ch,value)])
                self.assertEqual(len(packet),46)
                self.assertEqual(protocol.Decoder().decode(packet)[0]['value'],value)

    def test_feedback_encodings(self):
        self.assertEqual(protocol.button_led(28,16,True).hex(),'90105c')
        self.assertEqual(protocol.scribble(23,'ABCDE').hex(),'f0130140370041424344f7')
        self.assertEqual(protocol.ring(0,0).hex(),'f0130100400000f7')
        self.assertEqual(len(protocol.counter('01020304')),15)


class EngineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.engine = Engine(self.temp.name)

    def tearDown(self):
        self.engine.sock.close()
        self.temp.cleanup()

    def test_press_and_feedback_led_are_independent(self):
        self.engine.event('button:0:8',True)
        self.assertTrue(self.engine.pressed['button:0:8'])
        self.assertNotIn('button:0:8',self.engine.leds)
        self.engine.event('button:0:8',True,feedback=True)
        self.assertTrue(self.engine.leds['button:0:8'])
        self.assertEqual(sum(e['kind']=='route' for e in self.engine.events),1)

    def test_fader_feedback_defers_while_touched(self):
        self.engine.event('button:0:9',True)
        self.engine.event('fader:0',4000)
        self.engine.event('fader:0',8000,feedback=True)
        self.assertEqual(self.engine.values['fader:0'],4000)
        self.engine.event('button:0:9',False)
        self.assertEqual(self.engine.values['fader:0'],8000)

    def test_profile_switch_disarms_and_drops_old_feedback_state(self):
        self.engine.arm(True)
        self.engine.event('button:0:9',True)
        self.engine.event('fader:0',8000,feedback=True)
        self.engine.switch('mixbus')
        self.assertFalse(self.engine.armed)
        self.assertFalse(self.engine.pending)
        self.engine.event('button:0:9',False)
        self.assertNotIn('fader:0',self.engine.values)

    def test_desk_profile_keys_and_repeat(self):
        self.engine.event('button:24:35',True)  # Shift + Option + F4 = Mixbus
        self.engine.event('button:24:36',True)
        self.engine.event('button:24:6',True)
        self.assertEqual(self.engine.active,'mixbus')
        generation=self.engine.generation
        self.engine.event('button:24:6',True)
        self.assertEqual(self.engine.generation,generation)

    def test_udp_output_and_offline_replay_isolation(self):
        with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as receiver:
            receiver.bind(('127.0.0.1',0));receiver.settimeout(.15)
            profile=copy.deepcopy(self.engine.profile());profile['port']=receiver.getsockname()[1]
            self.engine.save_profile(profile)
            self.engine.event('fader:0',16383)
            with self.assertRaises(socket.timeout):receiver.recvfrom(1000)
            self.engine.arm(True)
            self.engine.event('fader:0',16383)
            packet,_=receiver.recvfrom(1000)
            self.assertEqual(osc.decode(packet),('/strip/fader',[1,1.0]))
            self.engine.raw(protocol.frame([protocol.fader_motor(0,0)]))
            with self.assertRaises(socket.timeout):receiver.recvfrom(1000)

    def test_osc_feedback_filters_source_and_does_not_route(self):
        self.engine.receive_osc(osc.encode('/strip/mute',[1,1]),'192.0.2.1')
        self.assertFalse(self.engine.leds)
        self.engine.receive_osc(osc.encode('/strip/mute',[1,1]),'127.0.0.1')
        self.assertTrue(self.engine.leds['button:0:8'])
        self.assertFalse(any(e['kind']=='route' for e in self.engine.events))

    def test_saved_profiles_survive_restart_but_output_does_not(self):
        profile=copy.deepcopy(self.engine.profile());profile['name']='Studio B';profile['host']='192.0.2.42'
        self.engine.save_profile(profile);self.engine.arm(True)
        reloaded=Engine(self.temp.name)
        try:
            self.assertEqual(reloaded.profile()['name'],'Studio B')
            self.assertFalse(reloaded.armed)
        finally:reloaded.sock.close()

    def test_invalid_values_and_unknowns(self):
        for value in (-1,16384,float('nan'),float('inf'),'120',True):
            with self.assertRaises(ValueError):self.engine.event('fader:0',value)
        self.engine.event('button:31:127',True)
        self.assertEqual(self.engine.events[-1]['kind'],'unknown')
        for port in (-1,65536,'3819'):
            profile=copy.deepcopy(self.engine.profile());profile['port']=port
            with self.assertRaises(ValueError):self.engine.save_profile(profile)


class OSCTests(unittest.TestCase):
    def test_typed_roundtrip(self):
        args=[1,-3,.5,'track one']
        self.assertEqual(osc.decode(osc.encode('/test',args)),('/test',args))

    def test_malformed_packets(self):
        for packet in (b'', b'/noterminator', b'#bundle\0', osc.encode('/test',[1])[:-1]):
            with self.assertRaises(ValueError):osc.decode(packet)


if __name__ == '__main__':
    unittest.main()
