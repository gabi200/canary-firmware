// ponytail: one runnable check for the room placement helpers (no test runner in this package):
//   node_modules/.bin/esbuild src/views/admin/roomModel.check.ts --bundle --platform=node --format=esm \
//     --jsx=automatic --outfile=/tmp/rm.mjs && node /tmp/rm.mjs
import { blockSpots, spotNear, uniqueName } from "./roomModel";
const eq = (a: unknown, b: unknown) => { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${JSON.stringify(a)} != ${JSON.stringify(b)}`); };
eq(uniqueName("Dormitor", ["Baie"]), "Dormitor");
eq(uniqueName("Dormitor", ["dormitor", "Dormitor 2"]), "Dormitor 3");
const kitchen = { x: 4, y: 2 };
eq(spotNear([kitchen], [kitchen]), { x: 7.5, y: 2 });                       // right of it
eq(spotNear([kitchen], [kitchen, { x: 7.5, y: 2 }]), { x: 4, y: 4.5 });      // right taken: below
console.log("roomModel ok");
eq(blockSpots([]), [{ x: 2, y: 2 }, { x: 5.5, y: 2 }, { x: 2, y: 4.5 }, { x: 5.5, y: 4.5 }]);
eq(blockSpots([{ x: 2, y: 2 }])[0], { x: 5.5, y: 2 }); // first block clear of the existing room
console.log("blockSpots ok");
