#!/usr/bin/env python3
"""Pure text cases for the kvc finding; reads no repository source."""
import unittest
from check_private_api import ROOT, findings_for

SAMPLE = ROOT / "Sources" / "Sample.swift"


def kvc(text):
    return sorted(target for kind, _, target in findings_for(SAMPLE, text) if kind == "kvc")


class KeyValueCodingFindingTests(unittest.TestCase):
    def test_literal_keys_are_found_in_any_spelling(self):
        self.assertEqual(kvc('let raw = connection.value(forKey: "auditToken")'), ["auditToken"])
        self.assertEqual(kvc('let raw = connection.value(forKey: #"auditToken"#)'), ["auditToken"])
        self.assertEqual(kvc('let raw = connection.value(\n    forKey: "auditToken"\n)'), ["auditToken"])
        self.assertEqual(kvc('let raw = connection.value(forKey /* why */: "auditToken")'), ["auditToken"])
        self.assertEqual(kvc('let raw = connection.value(forKey /* ) */: "auditToken")'), ["auditToken"])
        self.assertEqual(kvc('let raw = connection.value /* why */ (forKey: /* key */ "auditToken")'), ["auditToken"])
        self.assertEqual(kvc('let raw = object.value(forKeyPath: "a.b")'), ["a.b"])
        self.assertEqual(kvc('object.setValue(transform(make(value())), forKey: "privateKey")'), ["privateKey"])
        self.assertEqual(kvc('object.setValue("\\(transform(")"))", forKey: "privateKey")'), ["privateKey"])
        self.assertEqual(kvc('object.setValue(["a": (1, 2)], forKey: "map")'), ["map"])
        self.assertEqual(kvc('let list = object.mutableArrayValue(forKey: "items")'), ["items"])

    def test_keys_that_cannot_be_checked_are_reported(self):
        self.assertEqual(kvc("filter.setValue(image, forKey: kCIInputImageKey)"), ["<non-literal>"])
        self.assertEqual(kvc('let raw = object.value(forKey: "\\(prefix)Token")'), ["<non-literal>"])
        self.assertEqual(kvc('let raw = object.value(forKey: "audit\\u{54}oken")'), ["<non-literal>"])
        self.assertEqual(kvc('let raw = object.value(forKey: """\nauditToken\n""")'), ["<non-literal>"])
        self.assertEqual(kvc('let raw = object.value(forKey: "auditToken"'), ["<unparsed>"])

    def test_other_calls_and_text_are_not_key_value_coding(self):
        self.assertEqual(kvc('request.setValue("application/json", forHTTPHeaderField: "Accept")'), [])
        self.assertEqual(kvc('defaults.set(true, forKey: "flag"); let v = defaultValue(forKey: "k")'), [])
        self.assertEqual(kvc('let note = "call value(forKey: x"; let t = 1'), [])
        self.assertEqual(kvc('let s = object.value(at: 2, forUndefinedKey: "k")'), [])
        self.assertEqual(kvc('// let raw = object.value(forKey: "privateKey")'), [])
        self.assertEqual(kvc('/* old: object.value(forKey: "privateKey") /* nested */ */ let t = 1'), [])
        self.assertEqual(kvc('let note = "object.value(forKey: \\"privateKey\\")"'), [])
        self.assertEqual(kvc('let help = """\n  object.value(forKey: "privateKey")\n  """'), [])
        self.assertEqual(kvc('let note = #"object.value(forKey: "privateKey")"#'), [])


if __name__ == "__main__":
    unittest.main()
