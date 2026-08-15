// Pure, filesystem-agnostic helpers for learning and probing a camera's
// metadata-file naming convention. Each camera (机位) is assumed to write its
// sidecar with a fixed pattern, e.g. "<clip>-slate.txt" or a constant name like
// "camera-slate.txt". The walkers learn that pattern once per camera, then
// probe it directly instead of enumerating every clip folder.

// Default structure: the Kinefinity convention "<clip>-slate.txt". Used as a
// zero-cost seed so the common case never pays a learning enumeration.
export function defaultMetadataStructure() {
  return [{ dirnameSuffix: "-slate.txt" }];
}

// Given a clip folder name and the names of the metadata files found directly
// inside it, derive the probe templates. A template is either
//   { dirnameSuffix }  → the file is "<dirname><suffix>"
//   { fixedName }      → the file has a constant name
export function learnStructure(dirName, metadataFileNames) {
  const templates = [];
  for (const name of metadataFileNames) {
    if (name.startsWith(dirName)) {
      templates.push({ dirnameSuffix: name.slice(dirName.length) });
    } else {
      templates.push({ fixedName: name });
    }
  }
  return templates;
}

// Expand a structure into concrete candidate file names for a given clip dir.
export function probeNames(structure, dirName) {
  return (structure || []).map((template) =>
    template.dirnameSuffix != null
      ? `${dirName}${template.dirnameSuffix}`
      : template.fixedName,
  );
}
