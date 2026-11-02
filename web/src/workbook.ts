// FIT-292: an .xlsx (or .xls) upload, read in the browser with SheetJS into one text per tab, tab-separated as cells
// pasted from Excel arrive, so a tab goes through FIT-290's parse and preview like a paste. Loaded only when a workbook
// is picked, so the dashboard doesn't carry it otherwise.

export type Tab = { name: string; text: string };

/** Each tab with anything in it, in the workbook's order. */
export async function tabsOf(data: ArrayBuffer): Promise<Tab[]> {
  const XLSX = await import("xlsx");
  const book = XLSX.read(data, { type: "array" });
  return book.SheetNames.map((name) => ({ name, text: XLSX.utils.sheet_to_csv(book.Sheets[name], { FS: "\t", blankrows: false }).trim() }))
    .filter((tab) => tab.text.replace(/\t/g, "").trim());
}

export const isWorkbook = (file: { name: string }) => /\.(xlsx|xlsm|xls)$/i.test(file.name);
