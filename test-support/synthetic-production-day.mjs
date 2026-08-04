// Synthetic production-day fixture. It preserves difficult continuity patterns
// without retaining a project name, shoot date, or source-media identifier.
export function syntheticProductionDayGroundTruth() {
  const records = [];
  const addRange = (cardNumber, start, end, scene, shot, takeStart = 1) => {
    for (let clip = start; clip <= end; clip += 1) {
      records.push(makeRecord(
        cardNumber,
        clip,
        scene,
        shot,
        takeStart + clip - start,
      ));
    }
  };

  addRange("X101", 1, 9, 142, 1);
  addRange("X101", 10, 11, 142, 3);
  addRange("X101", 12, 13, 142, 4);
  addRange("X101", 14, 18, 142, 5);
  addRange("X101", 19, 21, 142, 6);
  addRange("X101", 22, 23, 142, 7);
  addRange("X101", 24, 27, 142, 12);

  addRange("Y201", 1, 1, 142, 1);
  addRange("Y201", 2, 7, 142, 2);
  addRange("Y201", 8, 8, 142, 3);
  addRange("Y201", 9, 10, 142, 4);
  addRange("Y201", 11, 11, 142, 5, 2);
  addRange("Y201", 12, 12, 142, 5, 4);
  addRange("Y201", 13, 13, 142, 5, 5);
  addRange("Y201", 14, 19, 142, 8);
  addRange("Y201", 20, 21, 142, 9);
  addRange("Y201", 22, 22, 142, 10);
  addRange("Y201", 23, 25, 142, 11);
  addRange("Y201", 26, 30, 142, 13);
  addRange("Y201", 31, 33, 142, 14);

  addRange("X102", 1, 8, 207, 1);
  addRange("X102", 9, 10, 207, 2);
  addRange("X102", 11, 23, 207, 5);
  addRange("X102", 24, 25, 207, 6);
  addRange("X102", 26, 33, 207, 7);
  addRange("X102", 34, 39, 207, 10);
  addRange("X102", 40, 44, 207, 11);
  addRange("X102", 45, 51, 207, 12);
  addRange("X102", 52, 56, 207, 13);
  addRange("X102", 57, 58, 207, 14);

  addRange("Y202", 1, 3, 207, 3);
  addRange("Y202", 4, 6, 207, 4);

  addRange("Y203", 1, 4, 207, 8);
  addRange("Y203", 5, 10, 207, 9);
  addRange("Y203", 11, 20, 207, 15);
  addRange("Y203", 21, 22, 207, 16);

  addRange("X103", 1, 10, 207, 17);
  addRange("X103", 11, 13, 207, 18);
  return records;
}

export function materialKey(record) {
  return `${record.cardNumber}${record.videoCode}`;
}

function makeRecord(cardNumber, clip, scene, shot, take) {
  return {
    cardNumber,
    videoCode: `C${String(clip).padStart(3, "0")}`,
    scene: String(scene).padStart(3, "0"),
    shot: String(shot).padStart(2, "0"),
    take: String(take).padStart(2, "0"),
    takeStatus: null,
    description: null,
    comments: null,
    shotSize: null,
    cameraPosition: null,
    confidence: "high",
  };
}
