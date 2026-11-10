// Patched async search for hotwire_combobox: abort the previous in-flight
// search so a slow response for an early query (e.g. "A") never overwrites
// the results for the final query (e.g. "AAPL").
//
// Aborting a search means its Turbo Stream will never arrive, so the
// callback hotwire_combobox enqueued for it can never run. That callback id
// has to leave the queue here: the queue is processed strictly in order, and
// a callback that never runs wedges it — every later search's selection is
// dropped instead of applied. A free-text query then has no value recorded
// when the combobox closes, and close() clears the typed text
// (hotwire_combobox 0.4.0: _clearInvalidQuery -> _clearQuery). On mobile this
// reads as "type a description, tap out, the description is gone".
export function patchHwComboboxAsyncSearch(HwComboboxController) {
  HwComboboxController.prototype._filterAsync = async function(inputType) {
    if (this._searchAbortController) {
      this._searchAbortController.abort()
    }

    // The aborted search's stream never arrives, so its callback can never
    // run and can never leave the queue on its own. Drop it now, or it stays
    // queued ahead of every later search and wedges the queue.
    if (this._searchCallbackId) {
      this._dequeueCallback(this._searchCallbackId)
    }

    this._searchAbortController = new AbortController()

    const query = {
      q: this._fullQuery,
      input_type: inputType,
      for_id: this.element.dataset.asyncId,
      callback_id: this._enqueueCallback()
    }

    this._searchCallbackId = query.callback_id

    const url = new URL(this.asyncSrcValue, window.location.origin)
    Object.entries(query).forEach(([k, v]) => {
      if (v != null) url.searchParams.set(k, v)
    })

    try {
      const response = await fetch(url.toString(), {
        headers: {
          "Accept": "text/vnd.turbo-stream.html, text/html, application/xhtml+xml",
          "X-Requested-With": "XMLHttpRequest",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content
        },
        signal: this._searchAbortController.signal,
        credentials: "same-origin"
      })

      if (response.ok) {
        await Turbo.renderStreamMessage(await response.text())
      }
    } catch (e) {
      if (e.name !== "AbortError") throw e
    }
  }
}
