// The exercise catalog the app ships (Resources/Seed), cut to what the dashboard shows: slug, name, equipment.
import { readFileSync, writeFileSync } from "node:fs";

const seed = JSON.parse(readFileSync(new URL("../../Resources/Seed/exercises.json", import.meta.url)));
const catalog = seed.map((t) => ({
  slug: t.slug,
  name: t.name,
  equipment: t.attributes.find((a) => a.key === "equipment")?.values ?? [],
}));
writeFileSync(new URL("../src/catalog.json", import.meta.url), JSON.stringify(catalog));
console.log(`catalog: ${catalog.length} exercises`);
