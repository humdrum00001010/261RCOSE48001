const EVENT_TOGGLE = "ecrits:document-element-picker.toggle"
const EVENT_STATE = "ecrits:document-element-picker.state"
const BUTTON_SELECTOR = "[data-role='document-element-picker-toggle']"
const COMPOSER_SELECTOR = "#local-agent-input"

const state = {
  enabled: false,
}

function setEnabled(enabled) {
  state.enabled = !!enabled
  document.body.dataset.documentElementPicker = String(state.enabled)

  for (const button of document.querySelectorAll(BUTTON_SELECTOR)) {
    button.setAttribute("aria-pressed", String(state.enabled))
    button.dataset.active = String(state.enabled)
  }

  document.dispatchEvent(new CustomEvent(EVENT_STATE, { detail: { enabled: state.enabled } }))
}

function toggle() {
  setEnabled(!state.enabled)
}

function pickedElementMarkdown(pick) {
  return [
    "Selected document element:",
    "```json",
    JSON.stringify(normalizePick(pick), null, 2),
    "```"
  ].join("\n")
}

function normalizePick(pick) {
  return {
    document: pick.document || "",
    backend: pick.backend || "",
    format: pick.format || "",
    type: pick.type || "unknown",
    ref: pick.ref || "",
    text: pick.text || "",
    ir: pick.ir || {}
  }
}

export function elementPickerEnabled() {
  return state.enabled
}

export function bindElementPickerTarget(target) {
  const apply = enabled => {
    target.elementPickerEnabled = !!enabled
    if (target.el) target.el.dataset.elementPicker = String(target.elementPickerEnabled)
  }

  const onState = event => apply(event.detail && event.detail.enabled)
  apply(state.enabled)
  document.addEventListener(EVENT_STATE, onState)

  return () => document.removeEventListener(EVENT_STATE, onState)
}

export function appendPickedElementToComposer(pick) {
  const input = document.querySelector(COMPOSER_SELECTOR)
  if (!input) return false

  const value = input.value || ""
  const prefix = value && !value.endsWith("\n") ? "\n\n" : ""
  input.value = `${value}${prefix}${pickedElementMarkdown(pick)}\n`
  input.dispatchEvent(new Event("input", { bubbles: true }))
  input.focus({ preventScroll: true })
  return true
}

document.addEventListener(EVENT_TOGGLE, event => {
  event.preventDefault()
  toggle()
})

document.addEventListener("keydown", event => {
  if (event.key === "Escape" && state.enabled) setEnabled(false)
})

window.EcritsDocumentElementPicker = {
  get enabled() {
    return state.enabled
  },
  setEnabled,
  toggle,
}
