// ANS-104 v2.0.0 bundle fixture generator.
//
// Produces two bundles:
//
//   bundle_v2.bin / .json / .fixt
//     Generic 2-item bundle used by the parser cross-check (A3).
//     Tag set is minimal — App-Name + Type — and is NOT a valid
//     ChannelChain Post.
//
//   bundle_v2_cc.bin / .json
//     Two ChannelChain Post items with the full required tag set
//     (Board-Id, Thread-Id, App-Version, Content-Type) and a JSON
//     body/name payload that satisfies ar_bbs_validator. Used by
//     the C3 end-to-end test.
//
// Usage (regeneration only — committed outputs are stable):
//   cd packages/chain/apps/arweave/test/fixtures
//   npm install arbundles arweave
//   node bundle_v2_gen.mjs

import { createData, bundleAndSignData, ArweaveSigner } from "arbundles";
import Arweave from "arweave";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const arweave = Arweave.init({});
const wallet = await arweave.wallets.generate();
const signer = new ArweaveSigner(wallet);

const item1 = createData("hello", signer, {
  tags: [
    { name: "App-Name", value: "ChannelChain" },
    { name: "Type", value: "Post" },
  ],
});
await item1.sign(signer);

const item2 = createData(Buffer.from("世界", "utf-8"), signer, {
  tags: [
    { name: "App-Name", value: "ChannelChain" },
    { name: "Type", value: "Thread" },
    { name: "Thread-Title", value: "テスト" },
  ],
});
await item2.sign(signer);

const bundle = await bundleAndSignData([item1, item2], signer);

const items = [item1, item2];

const expanded = await Promise.all(
  items.map(async (it) => ({
    idBuf: Buffer.from(it.id, "base64url"),
    sigType: it.signatureType,
    rawOwner: Buffer.from(it.rawOwner),
    rawSignature: Buffer.from(it.rawSignature),
    rawTarget: it.rawTarget && it.rawTarget.length > 0 ? Buffer.from(it.rawTarget) : null,
    rawAnchor: it.rawAnchor && it.rawAnchor.length > 0 ? Buffer.from(it.rawAnchor) : null,
    tags: it.tags,
    rawTags: Buffer.from(it.rawTags),
    rawData: Buffer.from(it.rawData),
    deepHash: Buffer.from(await it.getSignatureData()),
  })),
);

const itemsExpected = expanded.map((it) => ({
  id: it.idBuf.toString("base64url"),
  signatureType: it.sigType,
  ownerB64: it.rawOwner.toString("base64"),
  signatureB64: it.rawSignature.toString("base64"),
  target: it.rawTarget ? it.rawTarget.toString("base64url") : null,
  anchor: it.rawAnchor ? it.rawAnchor.toString("base64url") : null,
  tags: it.tags,
  rawTagsB64: it.rawTags.toString("base64"),
  dataB64: it.rawData.toString("base64"),
  deepHashB64: it.deepHash.toString("base64"),
}));

fs.writeFileSync(path.join(__dirname, "bundle_v2.bin"), Buffer.from(bundle.getRaw()));
fs.writeFileSync(
  path.join(__dirname, "bundle_v2.json"),
  JSON.stringify({ items: itemsExpected }, null, 2),
);
fs.writeFileSync(path.join(__dirname, "bundle_v2.fixt"), toErlangFixt(expanded));
console.log(`wrote bundle_v2.bin (${bundle.getRaw().length} bytes), ${expanded.length} items`);

// ---- ChannelChain Post bundle (full required tag set) ----

const boardId  = "00000000-0000-0000-0000-000000000001";
const threadId = "11111111-1111-1111-1111-111111111111";

const ccPostTags = (extra = []) => [
  { name: "App-Name",     value: "ChannelChain" },
  { name: "App-Version",  value: "1.0.0" },
  { name: "Content-Type", value: "application/json" },
  { name: "Type",         value: "Post" },
  { name: "Board-Id",     value: boardId },
  { name: "Thread-Id",    value: threadId },
  ...extra,
];

const ccPostBody = (body, name) => Buffer.from(JSON.stringify({ body, name }), "utf-8");

const ccItem1 = createData(ccPostBody("こんにちは", "名無しさん"), signer, { tags: ccPostTags() });
await ccItem1.sign(signer);
const ccItem2 = createData(ccPostBody("二つ目の投稿", "アノニ"),  signer, { tags: ccPostTags() });
await ccItem2.sign(signer);

const ccBundle = await bundleAndSignData([ccItem1, ccItem2], signer);
const ccItems  = [ccItem1, ccItem2];
const ccExpanded = await Promise.all(
  ccItems.map(async (it) => ({
    idBuf: Buffer.from(it.id, "base64url"),
    sigType: it.signatureType,
    rawOwner: Buffer.from(it.rawOwner),
    rawSignature: Buffer.from(it.rawSignature),
    rawTarget: it.rawTarget && it.rawTarget.length > 0 ? Buffer.from(it.rawTarget) : null,
    rawAnchor: it.rawAnchor && it.rawAnchor.length > 0 ? Buffer.from(it.rawAnchor) : null,
    tags: it.tags,
    rawTags: Buffer.from(it.rawTags),
    rawData: Buffer.from(it.rawData),
    deepHash: Buffer.from(await it.getSignatureData()),
  })),
);
fs.writeFileSync(path.join(__dirname, "bundle_v2_cc.bin"), Buffer.from(ccBundle.getRaw()));
fs.writeFileSync(
  path.join(__dirname, "bundle_v2_cc.json"),
  JSON.stringify(
    {
      items: ccExpanded.map((it) => ({
        id: it.idBuf.toString("base64url"),
        tags: it.tags,
        dataB64: it.rawData.toString("base64"),
      })),
    },
    null,
    2,
  ),
);
console.log(`wrote bundle_v2_cc.bin (${ccBundle.getRaw().length} bytes), ${ccExpanded.length} items`);

// ---- Erlang term emitters ----

function erlBin(buf) {
  if (buf.length === 0) return "<<>>";
  return "<<" + Array.from(buf).join(",") + ">>";
}

function erlOpt(buf) {
  return buf ? erlBin(buf) : "undefined";
}

function erlTag(t) {
  return `{${erlBin(Buffer.from(t.name, "utf-8"))}, ${erlBin(Buffer.from(t.value, "utf-8"))}}`;
}

function toErlangFixt(its) {
  const body = its
    .map(
      (it) => `  #{
    id => ${erlBin(it.idBuf)},
    signature_type => ${it.sigType},
    owner => ${erlBin(it.rawOwner)},
    signature => ${erlBin(it.rawSignature)},
    target => ${erlOpt(it.rawTarget)},
    anchor => ${erlOpt(it.rawAnchor)},
    tags => [${it.tags.map(erlTag).join(", ")}],
    tag_bytes => ${erlBin(it.rawTags)},
    data => ${erlBin(it.rawData)},
    deep_hash => ${erlBin(it.deepHash)}
  }`,
    )
    .join(",\n");
  return `%% Auto-generated by bundle_v2_gen.mjs. Do not edit.\n[\n${body}\n].\n`;
}
