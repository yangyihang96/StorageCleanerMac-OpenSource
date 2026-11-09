#!/usr/bin/env python3
"""Pure text cases for check_cjk_literals.py; reads no repository source."""
import unittest
from check_cjk_literals import blank_comments, findings_for


def literals(text):
    return [literal for _, literal in findings_for(text)]


class FindingTests(unittest.TestCase):
    def test_constructors_modifiers_and_properties_with_chinese_literals_are_found(self):
        self.assertEqual(literals('Text("项目产物").font(.title)'), ['"项目产物"'])
        self.assertEqual(literals('Button("选择文件夹") { choose() }'), ['"选择文件夹"'])
        self.assertEqual(literals('Toggle( "已核对", isOn: $on)'), ['"已核对"'])
        self.assertEqual(literals('Stepper("最近 \\(days) 天", value: $d)'), ['"最近 \\(days) 天"'])
        self.assertEqual(literals('view.help("模拟数据")'), ['"模拟数据"'])
        self.assertEqual(literals('.accessibilityLabel("扫描")'), ['"扫描"'])
        self.assertEqual(literals('panel.prompt = "选择扫描文件夹"'), ['"选择扫描文件夹"'])
        self.assertEqual(literals('alert.messageText = "没能启用"'), ['"没能启用"'])

    def test_localized_and_non_chinese_strings_are_not_findings(self):
        self.assertEqual(literals('Text(L10n.text("项目产物", "Project Artifacts"))'), [])
        self.assertEqual(literals('Button(L10n.text("关闭", "Close")) {}'), [])
        self.assertEqual(literals('Text("Storage")'), [])
        self.assertEqual(literals('Text(verbatim: "x")'), [])
        self.assertEqual(literals('let status = "扫描已取消"'), [], "a plain value is not a UI constructor")
        self.assertEqual(literals('MyText("项目")'), [], "only the SwiftUI names count")
        self.assertEqual(literals('x.Text("项目")'), [], "a member named Text is not the constructor")
        self.assertEqual(literals('Text("\\\\(a)：\\\\(b)")'), [], "full-width punctuation alone is not Chinese copy")

    def test_comments_and_multiline_literals_are_ignored_and_lines_can_opt_out(self):
        self.assertEqual(literals('// Text("项目产物")'), [])
        self.assertEqual(literals('/* Button("关闭") */ Text("ok")'), [])
        self.assertEqual(literals('let s = """\nText("项目")\n"""'), [])
        self.assertEqual(literals('Text("测试") // cjk-literal-ok: fixture name'), [])
        self.assertEqual(literals('Text("a // b 中")'), ['"a // b 中"'], "// inside a literal is not a comment")

    def test_blanking_keeps_line_numbers(self):
        text = 'a\n/* x\ny */\nText("中")'
        self.assertEqual(blank_comments(text).count("\n"), text.count("\n"))
        self.assertEqual(findings_for(text), [(4, '"中"')])


if __name__ == "__main__":
    unittest.main()
