"""Acceptance guards for reproducible selection and untrusted/incomplete logs."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('sd_runner',ROOT/'scripts/Compare-SdSceneTiming.py')
runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)

class TimingEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.inventory=runner.local_inventory();cls.entry=next(r for r in cls.inventory if r['name']=='RD0033.scn')
    def test_selection_reproducible_unique_with_known_controls(self):
        a=runner.select_200(self.inventory,200);b=runner.select_200(list(reversed(self.inventory)),200)
        self.assertEqual(a,b)
        self.assertEqual(len(a),200);self.assertEqual(len({r['caseId'] for r in a}),200)
        self.assertEqual({category:sum(r['category']==category for r in a) for category in ['largest','fastest','timing-controls','representative']},dict(largest=50,fastest=50,**{'timing-controls':50},representative=50))
        self.assertTrue(set(runner.PILOT_NAMES).issubset({r['name'] for r in a}))
    def test_qualification_unique_when_a_pilot_file_is_missing(self):
        rows=[r for r in self.inventory if r['name']!='APOLLO_13_009.scn'];selected=runner.select_200(rows,200)
        control=next(r for r in rows if r['name']=='afm01.scn')
        selected=[dict(control,category='timing-controls')]+selected
        q=runner.qualification_entries(rows,selected)
        self.assertEqual(len(q),10);self.assertEqual(len({r['caseId'] for r in q}),10)
    def test_log_requires_commit_and_correct_scene_identity(self):
        e=self.entry;steps=runner.ANALYZER.expected_steps(Path(e['path']).read_bytes());records=[];at=1000000
        header=dict(kind='header',schemaVersion=1,runId='run',caseId=e['caseId'],repeat=0,board='Waveshare7',variant='oldest',source='source',
            sha256=e['sha256'],nameHex=e['name'].encode().hex(),steps=e['steps'],frames=e['frames'],commandUs=999000,loadStartUs=999100,loadEndUs=999200)
        records.append(header)
        for n,(frame,delay) in enumerate(steps):
            records.append(dict(kind='step',n=n,frame=frame,delay=delay,loop=at-100,decoded=at,painted=at+100));at+=delay*1000
        records.extend([dict(kind='result',count=len(steps),start=1000000,end=at,status='Completed'),dict(kind='commit',count=len(steps))])
        encode=lambda data:('\n'.join(json.dumps(r) for r in data)+'\n').encode()
        with tempfile.TemporaryDirectory() as temporary:
            out=Path(temporary);(out/'Waveshare7').mkdir();(out/'Waveshare7/probe-source.json').write_text(json.dumps(dict(snapshots=dict(oldest='source'))))
            result=runner.validate_hardware(encode(records),e,'Waveshare7','oldest','run',0,out);self.assertEqual(result['actualMs'],e['expectedMs'])
            with self.assertRaises(RuntimeError):runner.validate_hardware(encode(records[:-1]),e,'Waveshare7','oldest','run',0,out)
            bad=copy.deepcopy(records);bad[0]['sha256']='0'*64
            with self.assertRaises(RuntimeError):runner.validate_hardware(encode(bad),e,'Waveshare7','oldest','run',0,out)
            bad=copy.deepcopy(records);bad[1]['delay']+=1
            with self.assertRaises(RuntimeError):runner.validate_hardware(encode(bad),e,'Waveshare7','oldest','run',0,out)
    def test_single_outlier_is_not_confirmed_difference(self):
        e=self.entry;rows=[]
        for target,values in [('Waveshare7/oldest',[1000,1000,1000]),('windows',[500,1000,1000])]:
            rows.extend(dict(target=target,caseId=e['caseId'],repeat=n,actualMs=value,skipped=0) for n,value in enumerate(values))
        c=next(c for c in runner.comparisons(rows,[e]) if c['reference']=='Waveshare7/oldest' and c['compared']=='windows');self.assertFalse(c['confirmed'])
        rows[-1]['actualMs']=500
        c=next(c for c in runner.comparisons(rows,[e]) if c['reference']=='Waveshare7/oldest' and c['compared']=='windows');self.assertTrue(c['confirmed'])
    def test_card_mismatch_is_visible_and_not_eligible(self):
        e=self.entry;inventory={b:[dict(name=e['name'],sha256=e['sha256'],bytes=e['bytes'])] for b in runner.BOARDS}
        inventory['Waveshare349B'][0]['sha256']='0'*64
        with tempfile.TemporaryDirectory() as temporary:
            out=Path(temporary);(out/'local-inventory.json').write_text(json.dumps([e]));aligned=runner.alignment(out,inventory)
            self.assertEqual(aligned,[]);report=json.loads((out/'alignment.json').read_text());self.assertEqual(report['issues'][0]['status']['Waveshare349B'],'different-content')
    def test_skips_and_shorter_duration_are_reported_separately(self):
        e=self.entry;rows=[]
        for target in ['Waveshare7/oldest','windows']:
            rows.extend(dict(target=target,caseId=e['caseId'],repeat=n,actualMs=1000,skipped=int(target=='windows' and n<2)) for n in range(3))
        pair=lambda:next(c for c in runner.comparisons(rows,[e]) if c['reference']=='Waveshare7/oldest' and c['compared']=='windows')
        c=pair();self.assertTrue(c['confirmed']);self.assertTrue(c['confirmedSkippedFrames']);self.assertFalse(c['confirmedDuration'])
        for row in rows:
            row['skipped']=0
            if row['target']=='windows':row['actualMs']=700
        c=pair();self.assertTrue(c['confirmedDuration']);self.assertFalse(c['confirmedSkippedFrames'])
    def test_normalized_rows_without_raw_evidence_do_not_count_as_completed(self):
        e=self.entry
        with tempfile.TemporaryDirectory() as temporary:
            out=Path(temporary);runner.save(out/'selected-200.json',[e]);runner.save(out/'run.json',dict(runId='run'));runner.save(out/'run-errors.json',[])
            for target in runner.TARGETS:
                path=runner.case_path(out,'sample',target,e,0);runner.save(path,dict(target=target,caseId=e['caseId'],repeat=0,status='Completed',actualMs=e['expectedMs'],skipped=0))
            runner.report(out);summary=json.loads((out/'summary.json').read_text())
            self.assertFalse(summary['complete']);self.assertEqual(summary['measurementCount'],0);self.assertEqual(len(summary['missingInitial']),5)

if __name__=='__main__':unittest.main()
