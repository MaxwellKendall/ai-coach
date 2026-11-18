#!/usr/bin/env node
// TKL-796: the only way agents install the app on Maxwell's phone. See scripts/device-install-lib.mjs.
import { run } from "./device-install-lib.mjs";

process.exitCode = await run(process.argv.slice(2));
