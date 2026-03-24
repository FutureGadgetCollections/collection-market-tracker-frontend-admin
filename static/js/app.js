// Triggers a backend sync for a specific resource and shows feedback on the button.
// The button must have a data-resource attribute (e.g. data-resource="sealed-products").
async function triggerSync(btn) {
  const resource = btn.dataset.resource;
  if (!resource) { showToast('Sync failed: missing data-resource on button.', 'danger'); return; }
  const original = btn.innerHTML;
  btn.disabled = true;
  btn.innerHTML = '<span class="spinner-border spinner-border-sm me-1"></span>Syncing…';
  try {
    await api('POST', `/sync/${resource}`);
    showToast('Sync triggered — data will update shortly.', 'success');
  } catch (e) {
    showToast('Sync failed: ' + e.message, 'danger');
  } finally {
    btn.disabled = false;
    btn.innerHTML = original;
  }
}

// Triggers a backend price sync and shows feedback on the button.
async function syncPrices(btn) {
  const original = btn.innerHTML;
  btn.disabled = true;
  btn.innerHTML = '<span class="spinner-border spinner-border-sm me-1"></span>Syncing…';
  try {
    await api('POST', '/sync/prices');
    showToast('Price sync triggered — data will update shortly.', 'success');
  } catch (e) {
    showToast('Price sync failed: ' + e.message, 'danger');
  } finally {
    btn.disabled = false;
    btn.innerHTML = original;
  }
}

// Global toast helper
function showToast(message, type = 'secondary') {
  let container = document.getElementById('toast-container');
  if (!container) {
    container = document.createElement('div');
    container.id = 'toast-container';
    container.className = 'toast-container position-fixed bottom-0 end-0 p-3';
    document.body.appendChild(container);
  }
  const id = 'toast-' + Date.now();
  container.insertAdjacentHTML('beforeend', `
    <div id="${id}" class="toast align-items-center text-bg-${type} border-0" role="alert">
      <div class="d-flex">
        <div class="toast-body">${message}</div>
        <button type="button" class="btn-close btn-close-white me-2 m-auto" data-bs-dismiss="toast"></button>
      </div>
    </div>
  `);
  const el = document.getElementById(id);
  new bootstrap.Toast(el, { delay: 4000 }).show();
  el.addEventListener('hidden.bs.toast', () => el.remove());
}
