import test from "node:test";
import assert from "node:assert/strict";
import {
  calculateCoreColumnWidth,
  calculateDetailSegments,
  findDenseRowBand,
} from "../public/image-preprocess.js";

function whiteImage(width, height) {
  const data = new Uint8ClampedArray(width * height * 4);
  data.fill(255);
  return { data, width, height };
}

function drawDarkRow(image, y, from = 0, to = image.width) {
  for (let x = from; x < to; x += 1) {
    const offset = (y * image.width + x) * 4;
    image.data[offset] = 30;
    image.data[offset + 1] = 30;
    image.data[offset + 2] = 30;
  }
}

test("dense table rows crop large vertical whitespace while ignoring a stray page edge", () => {
  const image = whiteImage(512, 724);
  for (let y = 190; y <= 520; y += 12) drawDarkRow(image, y, 35, 480);
  drawDarkRow(image, 710);

  const bounds = findDenseRowBand(image);

  assert.equal(bounds.cropped, true);
  assert.ok(bounds.top < 190);
  assert.ok(bounds.top > 130);
  assert.ok(bounds.bottom > 520);
  assert.ok(bounds.bottom < 600);
});

test("blank or weakly marked pages keep their full height", () => {
  const blank = whiteImage(200, 300);
  assert.deepEqual(findDenseRowBand(blank), {
    top: 0,
    bottom: 300,
    cropped: false,
  });

  for (let y = 140; y < 145; y += 1) drawDarkRow(blank, y, 0, 8);
  assert.equal(findDenseRowBand(blank).cropped, false);
});

test("detail segments repeat one header and cover the entire table body with overlap", () => {
  const layout = calculateDetailSegments(1000);

  assert.deepEqual(layout.header, { top: 0, bottom: 220 });
  assert.equal(layout.segments[0].top, 220);
  assert.equal(layout.segments[1].bottom, 1000);
  assert.ok(layout.segments[0].bottom > layout.segments[1].top);
  assert.ok(layout.segments[0].bottom - layout.segments[1].top >= 80);
});

test("core-column detail views crop away narrative columns to enlarge handwritten numbers", () => {
  assert.equal(calculateCoreColumnWidth(3000), 1860);
  assert.equal(calculateCoreColumnWidth(1000, 0.4), 500);
  assert.equal(calculateCoreColumnWidth(1000, 2), 1000);
});
