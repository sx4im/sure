import { describe, it, beforeEach, afterEach } from "node:test"
import assert from "node:assert/strict"

import { patchHwComboboxAsyncSearch } from "../../../app/javascript/utils/hw_combobox_async_search.js"

// Minimal stand-in for hotwire_combobox 0.4.0's HwComboboxController. The
// callback queue methods below mirror the gem's Callbacks concern and
// _runCallback verbatim, so the test exercises the real queue invariant the
// patch must maintain: callbacks run strictly in queue order, and a callback
// whose Turbo Stream never arrives wedges the queue for every later search.
const MAX_CALLBACK_ATTEMPTS = 3

class FakeHwComboboxController {
  constructor() {
    this.callbackQueue = []
    this.callbackExecutionAttempts = {}
    this.element = { dataset: { asyncId: "test-id" } }
    this.asyncSrcValue = "/transactions/name_suggestions"
    this._fullQuery = ""
    this.hiddenFieldValue = ""
    this.selections = []
  }

  _enqueueCallback() {
    const callbackId = `cb-${Math.random().toString(36).slice(2, 8)}`
    this.callbackQueue.push(callbackId)
    return callbackId
  }

  _isNextCallback(callbackId) {
    return this.callbackQueue[0] === callbackId
  }

  _callbackAttemptsExceeded(callbackId) {
    return (this.callbackExecutionAttempts[callbackId] || 0) > MAX_CALLBACK_ATTEMPTS
  }

  _callbackAttempts(callbackId) {
    return this.callbackExecutionAttempts[callbackId] || 0
  }

  _recordCallbackAttempt(callbackId) {
    this.callbackExecutionAttempts[callbackId] = this._callbackAttempts(callbackId) + 1
  }

  _dequeueCallback(callbackId) {
    this.callbackQueue = this.callbackQueue.filter((id) => id !== callbackId)
    delete this.callbackExecutionAttempts[callbackId]
  }

  async _runCallback(element) {
    const callbackId = element.dataset.callbackId

    if (this._callbackAttemptsExceeded(callbackId)) {
      return this._dequeueCallback(callbackId)
    } else {
      this._recordCallbackAttempt(callbackId)
    }

    if (this._isNextCallback(callbackId)) {
      await new Promise((resolve) => setTimeout(resolve, 0))
      this._dequeueCallback(callbackId)
      this._selectOnQuery(element.dataset.inputType)
    } else {
      await new Promise((resolve) => setTimeout(resolve, 0))
      this._runCallback(element)
    }
  }

  // Free-text stand-in for the gem's _selectOnQuery -> _selectNew: the typed
  // query becomes the recorded value.
  _selectOnQuery() {
    this.selections.push(this._fullQuery)
    this.hiddenFieldValue = this._fullQuery
  }

  // Models the gem's close() -> _clearInvalidQuery: the visible query is
  // wiped when no value was ever recorded and no option was selected.
  closeWipesQuery() {
    return this.hiddenFieldValue === ""
  }
}

function deferredFetch() {
  let release
  let abortListener
  const promise = new Promise((resolve, reject) => {
    release = () => resolve({ ok: true, text: async () => "<turbo-stream></turbo-stream>" })
    abortListener = () => {
      const error = new Error("AbortError")
      error.name = "AbortError"
      reject(error)
    }
  })
  return { promise, release, abortListener }
}

describe("patchHwComboboxAsyncSearch", () => {
  let fetchCalls
  let renderedStreams
  let originalFetch
  let originalTurbo
  let originalDocument
  let originalWindow

  beforeEach(() => {
    fetchCalls = []
    renderedStreams = []
    originalFetch = globalThis.fetch
    originalTurbo = globalThis.Turbo
    originalDocument = globalThis.document
    originalWindow = globalThis.window

    globalThis.fetch = (url, init) => {
      const deferred = deferredFetch()
      init.signal.addEventListener("abort", deferred.abortListener, { once: true })
      fetchCalls.push({ url, init, release: deferred.release })
      return deferred.promise
    }
    globalThis.Turbo = {
      renderStreamMessage: async (text) => { renderedStreams.push(text) },
    }
    globalThis.document = { querySelector: () => null }
    globalThis.window = { location: { origin: "http://test.host" } }
  })

  afterEach(() => {
    globalThis.fetch = originalFetch
    globalThis.Turbo = originalTurbo
    globalThis.document = originalDocument
    globalThis.window = originalWindow
  })

  function patchedController() {
    class Controller extends FakeHwComboboxController {}
    patchHwComboboxAsyncSearch(Controller)
    return new Controller()
  }

  it("an aborted search's callback leaves the queue, so the next search still selects", async () => {
    const controller = patchedController()

    // First search is still in flight when the second one fires.
    controller._fullQuery = "My custom"
    const firstSearch = controller._filterAsync("insertText")
    const firstCallbackId = controller.callbackQueue.at(-1)

    controller._fullQuery = "My custom purchase"
    const secondSearch = controller._filterAsync("insertText")
    const secondCallbackId = controller.callbackQueue.at(-1)

    // The first fetch was aborted, and its callback is gone: it can never
    // run, so leaving it queued would wedge every later search.
    assert.equal(fetchCalls.length, 2)
    assert.equal(controller.callbackQueue.length, 1)
    assert.equal(controller.callbackQueue[0], secondCallbackId)
    assert.notEqual(controller.callbackQueue[0], firstCallbackId)

    // The second search's stream arrives and its selection runs.
    fetchCalls[1].release()
    await secondSearch
    assert.equal(renderedStreams.length, 1)
    await controller._runCallback({ dataset: { callbackId: secondCallbackId, inputType: "insertText" } })
    assert.deepEqual(controller.selections, ["My custom purchase"])
    assert.equal(controller.hiddenFieldValue, "My custom purchase")

    // Closing the combobox now keeps the typed description.
    assert.equal(controller.closeWipesQuery(), false)

    await firstSearch
  })

  it("a search that is never aborted selects as before", async () => {
    const controller = patchedController()

    controller._fullQuery = "Starbucks"
    const search = controller._filterAsync("insertText")
    const callbackId = controller.callbackQueue.at(-1)

    fetchCalls[0].release()
    await search
    await controller._runCallback({ dataset: { callbackId, inputType: "insertText" } })

    assert.deepEqual(controller.selections, ["Starbucks"])
    assert.equal(controller.closeWipesQuery(), false)
  })

  it("aborts the previous in-flight search when a new one fires", async () => {
    const controller = patchedController()

    controller._fullQuery = "A"
    const firstSearch = controller._filterAsync("insertText")

    controller._fullQuery = "AP"
    const secondSearch = controller._filterAsync("insertText")

    assert.equal(fetchCalls[0].init.signal.aborted, true)
    assert.equal(fetchCalls[1].init.signal.aborted, false)

    fetchCalls[1].release()
    await secondSearch
    await firstSearch
  })
})
