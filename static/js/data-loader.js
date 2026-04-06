// Fetches a JSON file from GitHub Raw. Returns parsed JSON.
// Requires window.DATA_CONFIG = { gcsBucket, githubDataRepo }
async function loadFromGitHub(filename) {
  const { githubDataRepo } = window.DATA_CONFIG || {};
  if (!githubDataRepo) throw new Error('DATA_CONFIG.githubDataRepo is not set');
  const url = `https://raw.githubusercontent.com/${githubDataRepo}/main/${filename}?t=${Date.now()}`;
  console.debug(`[data-loader] GitHub: ${url}`);
  const res = await fetch(url);
  if (!res.ok) throw new Error(`GitHub returned ${res.status} for ${filename}`);
  return res.json();
}

// Fetches a JSON file from GCS. Returns parsed JSON.
async function loadFromGCS(filename) {
  const { gcsBucket } = window.DATA_CONFIG || {};
  if (!gcsBucket) throw new Error('DATA_CONFIG.gcsBucket is not set');
  const url = `https://storage.googleapis.com/${gcsBucket}/${filename}?t=${Date.now()}`;
  console.debug(`[data-loader] GCS: ${url}`);
  const res = await fetch(url);
  if (!res.ok) throw new Error(`GCS returned ${res.status} for ${filename}`);
  return res.json();
}

// Tries GCS first, falls back to GitHub.
async function loadJsonData(filename) {
  const { gcsBucket, githubDataRepo } = window.DATA_CONFIG || {};
  console.debug(`[data-loader] loading ${filename} | bucket=${gcsBucket} | repo=${githubDataRepo}`);
  try {
    return await loadFromGCS(filename);
  } catch (e) {
    console.warn(`[data-loader] GCS failed for ${filename}:`, e.message, '— falling back to GitHub');
  }
  return loadFromGitHub(filename);
}
