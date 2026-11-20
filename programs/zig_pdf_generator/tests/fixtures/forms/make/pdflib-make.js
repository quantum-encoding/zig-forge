// Builds a filled AcroForm entirely with pdf-lib (object streams + xref
// stream, pdf-lib's default), saves it to argv[2], then re-opens the saved
// bytes with pdf-lib and writes what pdf-lib reads back to argv[3] in the
// reader's value shapes: text → string (left out when unset), checkbox →
// bool, radio → chosen option (left out when none), dropdown → string,
// multi-select list → array.
const fs = require('fs');
const lib = require(process.env.PDF_LIB || 'pdf-lib');
const { PDFDocument, StandardFonts, PDFTextField, PDFCheckBox, PDFRadioGroup, PDFDropdown, PDFOptionList } = lib;

(async () => {
  const doc = await PDFDocument.create();
  const font = await doc.embedFont(StandardFonts.Helvetica);
  const page = doc.addPage([595, 842]);
  const form = doc.getForm();
  let y = 780;
  const box = () => ({ x: 200, y: (y -= 30), width: 200, height: 18, font });

  const name = form.createTextField('name'); name.setText('Ada (Lovelace) \\ ok'); name.addToPage(page, box());
  const uni = form.createTextField('unicode'); uni.addToPage(page, box()); uni.setText('Zoë – Łódź €5');
  const notes = form.createTextField('notes'); notes.enableMultiline(); notes.setText('line1\nline2'); notes.addToPage(page, { ...box(), height: 40 });
  const date = form.createTextField('inspection.date'); date.setText('2026-11-19'); date.addToPage(page, box());
  const blank = form.createTextField('blank'); blank.addToPage(page, box());
  const agree = form.createCheckBox('agree'); agree.addToPage(page, { ...box(), width: 14, height: 14 }); agree.check();
  const decline = form.createCheckBox('decline'); decline.addToPage(page, { ...box(), width: 14, height: 14 });
  const phase = form.createRadioGroup('phase');
  phase.addOptionToPage('single', page, { ...box(), width: 14, height: 14 });
  phase.addOptionToPage('three', page, { x: 230, y, width: 14, height: 14 });
  phase.select('three');
  const board = form.createDropdown('board'); board.addOptions(['A', 'B']); board.select('B'); board.addToPage(page, box());
  const tests = form.createOptionList('tests'); tests.addOptions(['IR', 'Zs', 'RCD']); tests.enableMultiselect();
  tests.select(['IR', 'RCD']); tests.addToPage(page, { ...box(), height: 50 });

  // Non-WinAnsi text (Ł, ź) cannot be drawn with standard Helvetica, so the
  // appearances are left to the viewer (pdf-lib then sets NeedAppearances).
  const bytes = await doc.save({ useObjectStreams: true, updateFieldAppearances: false });
  fs.writeFileSync(process.argv[2], bytes);

  const back = (await PDFDocument.load(bytes)).getForm();
  const out = {};
  for (const f of back.getFields()) {
    const n = f.getName();
    if (f instanceof PDFTextField) { const t = f.getText(); if (t !== undefined) out[n] = t; }
    else if (f instanceof PDFCheckBox) out[n] = f.isChecked();
    else if (f instanceof PDFRadioGroup) { const s = f.getSelected(); if (s !== undefined) out[n] = s; }
    else if (f instanceof PDFDropdown) out[n] = f.getSelected()[0];
    else if (f instanceof PDFOptionList) out[n] = f.getSelected();
  }
  fs.writeFileSync(process.argv[3], JSON.stringify(out, null, 2) + '\n');
  console.log(JSON.stringify(out));
})().catch(e => { console.error(e); process.exit(1); });
