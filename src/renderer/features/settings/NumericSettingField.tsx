import { useGlobalSettingsStore } from "../../state";
import { isGlobalSettingLocked } from "../../state/global-settings-store";

export function useSettingLocked(key?: GlobalSettingKey) {
  return useGlobalSettingsStore((state) => isGlobalSettingLocked(state, key));
}
import { Field, Input, Select } from "../../design-system";
import type { GlobalSettingKey } from "../../../shared/contracts/index.js";
import { GLOBAL_TIMEOUT_RANGES, validateGlobalSettingValue } from "../../validation/global-settings-validation";

interface SettingFieldBaseProps {
  settingKey: GlobalSettingKey;
  label: string;
  hint?: string | undefined;
  /** Shown when neither a draft nor the saved snapshot provides a value. */
  fallback?: string | undefined;
  placeholder?: string | undefined;
  disabled?: boolean | undefined;
  spellCheck?: boolean | undefined;
}

function useFieldValue(settingKey: GlobalSettingKey, fallback: string | undefined) {
  // Primitive selector: typing only re-renders this field's subtree.
  return useGlobalSettingsStore((state) => state.draftValues[settingKey] ?? state.saved?.values[settingKey] ?? fallback ?? "");
}

function useFieldError(settingKey: GlobalSettingKey) {
  return useGlobalSettingsStore((state) => state.fieldErrors[settingKey]);
}

function commitValue(settingKey: GlobalSettingKey, value: string) {
  useGlobalSettingsStore.getState().setDraftValue(settingKey, value);
}

/**
 * Blur-time validation for numeric and timeout settings; other keys simply
 * clear a stale error so the save gate reflects the latest input.
 */
function validateOnBlur(settingKey: GlobalSettingKey, value: string) {
  const store = useGlobalSettingsStore.getState();
  const result = validateGlobalSettingValue(settingKey, value);
  store.setFieldError(settingKey, result.ok ? null : result.message);
}

export type NumericSettingFieldProps = SettingFieldBaseProps & {
  min?: string | undefined;
  max?: string | undefined;
  step?: string | undefined;
  /**
   * Preset preview override: named Paddle presets show their read-only
   * effective values instead of the stored (empty) draft.
   */
  overrideValue?: string | undefined;
};

export function NumericSettingField({ settingKey, label, hint, fallback, placeholder, disabled, overrideValue, min, max, step }: NumericSettingFieldProps) {
  const locked = useSettingLocked(settingKey);
  const storedValue = useFieldValue(settingKey, fallback);
  const error = useFieldError(settingKey);
  // Timeout keys accept the literal "auto", so they stay free-text inputs.
  const inputType = settingKey in GLOBAL_TIMEOUT_RANGES ? "text" : "number";
  // Preset previews are display-only; validation only applies to stored input.
  const showValue = overrideValue !== undefined ? overrideValue : storedValue;
  return <Field label={label} hint={hint} error={error}>
    <Input
      type={inputType}
      min={min}
      max={max}
      step={step}
      value={showValue}
      placeholder={placeholder}
      disabled={disabled || locked}
      onChange={(event) => commitValue(settingKey, event.target.value)}
      onBlur={() => { if (overrideValue === undefined) validateOnBlur(settingKey, storedValue); }}
    />
  </Field>;
}

export function TextSettingField({ settingKey, label, hint, fallback, placeholder, disabled, spellCheck }: SettingFieldBaseProps) {
  const locked = useSettingLocked(settingKey);
  const value = useFieldValue(settingKey, fallback);
  const error = useFieldError(settingKey);
  return <Field label={label} hint={hint} error={error}>
    <Input
      value={value}
      placeholder={placeholder}
      disabled={disabled || locked}
      spellCheck={spellCheck}
      onChange={(event) => commitValue(settingKey, event.target.value)}
      onBlur={() => useGlobalSettingsStore.getState().setFieldError(settingKey, null)}
    />
  </Field>;
}

export function SelectSettingField({ settingKey, label, hint, fallback, options, disabled }: SettingFieldBaseProps & { options: ReadonlyArray<{ value: string; label: string }> }) {
  const locked = useSettingLocked(settingKey);
  const value = useFieldValue(settingKey, fallback);
  return <Field label={label} hint={hint}>
    <Select value={value} disabled={disabled || locked} onChange={(event) => commitValue(settingKey, event.target.value)}>
      {options.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
    </Select>
  </Field>;
}
