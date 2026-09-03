import io
import os
import tempfile
import unittest
from contextlib import redirect_stdout

import analyze_mysql_results as script


class AnalyzeMySQLResultsTests(unittest.TestCase):
    def write_csv(self, content):
        temp = tempfile.NamedTemporaryFile('w', delete=False, encoding='utf-8', suffix='.csv')
        self.addCleanup(lambda: os.unlink(temp.name) if os.path.exists(temp.name) else None)
        temp.write(content)
        temp.close()
        return temp.name

    def test_read_csv_data_fills_missing_sysbench_script(self):
        path = self.write_csv(
            "MySQL build,Sysbench script,Transactions/sec,Queries/sec,Memory peak (kb),Read ops,Write ops,Other ops,Total\n"
            "orig,oltp-read-write.lua,242.25,4845.49,445380,610596,174441,87222,872259\n"
            "tsan-dom_peeling-ea-lo-st-swmr,29.86,597.39,3249184,75348,21526,10763,107637\n"
        )

        header, rows = script.read_csv_data(path)

        self.assertEqual(header[1], 'Sysbench script')
        self.assertEqual(rows[1][1], 'oltp-read-write.lua')
        self.assertEqual(rows[1][-1], '107637')
        self.assertEqual(len(rows[1]), len(header))

    def test_process_and_print_summary_handles_shifted_rows(self):
        path = self.write_csv(
            "MySQL build,Sysbench script,Transactions/sec,Queries/sec,Memory peak (kb),Read ops,Write ops,Other ops,Total\n"
            "orig,oltp-read-write.lua,242.25,4845.49,445380,610596,174441,87222,872259\n"
            "tsan,oltp-read-write.lua,27.45,549.01,3451288,69230,19780,9890,98900\n"
            "tsan-dom_peeling,28.15,563.11,3404468,71008,20282,10142,101432\n"
        )

        output = io.StringIO()
        with redirect_stdout(output):
            script.process_and_print_summary(path)

        rendered = output.getvalue()
        self.assertIn('Performance and Memory Summary', rendered)
        self.assertIn('orig', rendered)
        self.assertIn('tsan', rendered)
        self.assertIn('tsan-dom_peeling', rendered)
        self.assertIn('101432.00', rendered)


if __name__ == '__main__':
    unittest.main()

