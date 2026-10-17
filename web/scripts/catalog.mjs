// The exercise catalog the app ships (Resources/Seed), cut to what the dashboard uses: slug, name, equipment, and the
// movement pattern and tags that pick what Claude chooses from when designing (FIT-141).
import { readFileSync, writeFileSync } from "node:fs";

const seed = JSON.parse(readFileSync(new URL("../../Resources/Seed/exercises.json", import.meta.url)));
const catalog = seed.map((t) => ({
  slug: t.slug,
  name: t.name,
  equipment: t.attributes.find((a) => a.key === "equipment")?.values ?? [],
  pattern: t.attributes.find((a) => a.key === "movement_pattern")?.values?.[0] ?? null,
  tags: t.attributes.find((a) => a.key === "tags")?.values ?? [],
}));
writeFileSync(new URL("../src/catalog.json", import.meta.url), JSON.stringify(catalog));
console.log(`catalog: ${catalog.length} exercises`);
