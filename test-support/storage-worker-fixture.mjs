// Test-only worker bootstrap: a synthetic key never touches the login keychain.
// Production bootstrap has no key injection RPC or test command surface.
import { parentPort } from "node:worker_threads";
import { withEncryptionKeyProvider } from "../lib/local-encryption.mjs";
import { startStorageWorker } from "../lib/storage-worker.mjs";
export const SYNTHETIC_KEY = Buffer.alloc(32, 0x73);
if (parentPort) startStorageWorker(parentPort, {
  runWithContext: (operation) => withEncryptionKeyProvider(() => SYNTHETIC_KEY, operation),
});
