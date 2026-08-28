import { Check, ChevronDown, ChevronRight } from "lucide-react";
import { useEffect, useId, useLayoutEffect, useMemo, useRef, useState, type FocusEvent, type KeyboardEvent } from "react";
import type { ModelData } from "../../../shared/contracts/index.js";
import styles from "../../app/app.module.css";
import { modelOptionLabel, type ModelOptionGroup } from "./model-options";

type ModelSelectProps = {
  value: string;
  groups: readonly ModelOptionGroup[];
  onChange: (value: string) => void;
  placeholder: string;
  disabled?: boolean;
  id?: string;
  "aria-describedby"?: string;
  "aria-invalid"?: boolean;
  "data-state"?: "error" | "success";
};

type SelectedModel = {
  group: ModelOptionGroup;
  model: ModelData;
};

type MenuPosition = {
  left: number;
  width: number;
  maxHeight: number;
  top?: number;
  bottom?: number;
};

/**
 * A native select cannot collapse optgroups, so this keeps fixed recommendations
 * visible while exposing discovered vendor buckets through disclosure buttons.
 * The root also stops clicks from bubbling through Field's wrapping label.
 */
export function ModelSelect({
  value,
  groups,
  onChange,
  placeholder,
  disabled = false,
  id,
  "aria-describedby": ariaDescribedBy,
  "aria-invalid": ariaInvalid,
  "data-state": dataState,
}: ModelSelectProps) {
  const [open, setOpen] = useState(false);
  const [expandedGroups, setExpandedGroups] = useState<Set<string>>(() => new Set());
  const [menuPosition, setMenuPosition] = useState<MenuPosition | null>(null);
  const rootRef = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const instanceId = useId().replace(/:/g, "");
  const listboxId = "model-picker-" + instanceId;

  const selected = useMemo<SelectedModel | null>(() => {
    for (const group of groups) {
      const model = group.models.find((candidate) => candidate.id === value);
      if (model) return { group, model };
    }
    return null;
  }, [groups, value]);

  useEffect(() => {
    if (!open) return undefined;
    const closeOnOutsidePointer = (event: PointerEvent) => {
      if (event.target instanceof Node && !rootRef.current?.contains(event.target)) {
        setOpen(false);
      }
    };
    const closeOnEscape = (event: globalThis.KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      setOpen(false);
      triggerRef.current?.focus();
    };
    document.addEventListener("pointerdown", closeOnOutsidePointer);
    document.addEventListener("keydown", closeOnEscape);
    return () => {
      document.removeEventListener("pointerdown", closeOnOutsidePointer);
      document.removeEventListener("keydown", closeOnEscape);
    };
  }, [open]);

  useLayoutEffect(() => {
    if (!open) {
      setMenuPosition(null);
      return undefined;
    }
    const updateMenuPosition = () => {
      const triggerRect = triggerRef.current?.getBoundingClientRect();
      if (!triggerRect) return;
      const gap = 6;
      const viewportPadding = 12;
      const preferredHeight = 320;
      const availableBelow = Math.max(0, window.innerHeight - triggerRect.bottom - gap - viewportPadding);
      const availableAbove = Math.max(0, triggerRect.top - gap - viewportPadding);
      const openBelow =
        availableBelow >= Math.min(preferredHeight, window.innerHeight - viewportPadding * 2) ||
        availableBelow >= availableAbove;
      const availableHeight = openBelow ? availableBelow : availableAbove;
      setMenuPosition({
        left: triggerRect.left,
        width: triggerRect.width,
        maxHeight: Math.min(440, availableHeight),
        ...(openBelow
          ? { top: triggerRect.bottom + gap }
          : { bottom: window.innerHeight - triggerRect.top + gap }),
      });
    };
    // A fixed menu escapes scroll containers; closing on scroll avoids leaving
    // the list behind when an ancestor moves the trigger.
    const closeOnScroll = (event: Event) => {
      if (event.target instanceof Node && rootRef.current?.contains(event.target)) return;
      setOpen(false);
    };
    updateMenuPosition();
    window.addEventListener("resize", updateMenuPosition);
    document.addEventListener("scroll", closeOnScroll, true);
    return () => {
      window.removeEventListener("resize", updateMenuPosition);
      document.removeEventListener("scroll", closeOnScroll, true);
    };
  }, [open]);

  const triggerLabel = selected
    ? modelOptionLabel(selected.model)
    : value
      ? value + " · 已保存（当前未加载）"
      : placeholder;

  const openPicker = () => {
    if (disabled) return;
    if (!open && selected?.group.collapsible) {
      setExpandedGroups((current) => new Set(current).add(selected.group.key));
    }
    setOpen((current) => !current);
  };

  const toggleGroup = (groupKey: string) => {
    setExpandedGroups((current) => {
      const next = new Set(current);
      if (next.has(groupKey)) next.delete(groupKey);
      else next.add(groupKey);
      return next;
    });
  };

  const chooseModel = (modelId: string) => {
    onChange(modelId);
    setOpen(false);
    triggerRef.current?.focus();
  };

  const handleRootBlur = (event: FocusEvent<HTMLDivElement>) => {
    const nextTarget = event.relatedTarget;
    if (!(nextTarget instanceof Node) || !rootRef.current?.contains(nextTarget)) {
      setOpen(false);
    }
  };

  const handleTriggerKeyDown = (event: KeyboardEvent<HTMLButtonElement>) => {
    if (open || !["Enter", " ", "ArrowDown", "ArrowUp"].includes(event.key)) return;
    event.preventDefault();
    openPicker();
  };

  return (
    <div ref={rootRef} className={styles.modelPicker} onBlur={handleRootBlur} onClick={(event) => event.stopPropagation()}>
      <button
        ref={triggerRef}
        id={id}
        type="button"
        className={styles.modelPickerTrigger}
        data-open={open || undefined}
        data-state={dataState}
        aria-describedby={ariaDescribedBy}
        aria-expanded={open}
        aria-haspopup="listbox"
        aria-controls={listboxId}
        aria-invalid={ariaInvalid}
        disabled={disabled}
        onClick={openPicker}
        onKeyDown={handleTriggerKeyDown}
      >
        <span className={styles.modelPickerTriggerLabel} data-placeholder={!value || undefined}>{triggerLabel}</span>
        <ChevronDown className={styles.modelPickerTriggerIcon} size={16} aria-hidden="true" />
      </button>
      {open && (
        <div
          id={listboxId}
          className={styles.modelPickerMenu}
          role="listbox"
          aria-label="模型列表"
          style={menuPosition || { visibility: "hidden" }}
        >
          {!groups.length && <div className={styles.modelPickerEmpty}>暂无可用模型</div>}
          {groups.map((group) => {
            const collapsible = group.collapsible === true;
            const expanded = !collapsible || expandedGroups.has(group.key);
            const groupOptionsId = listboxId + "-" + group.key;
            return (
              <section className={styles.modelPickerGroup} key={group.key}>
                {collapsible ? (
                  <button
                    type="button"
                    className={styles.modelPickerGroupHeader}
                    data-expanded={expanded}
                    aria-expanded={expanded}
                    aria-controls={groupOptionsId}
                    onClick={() => toggleGroup(group.key)}
                  >
                    <ChevronRight className={styles.modelPickerGroupHeaderIcon} size={14} aria-hidden="true" />
                    <span>{group.label}</span>
                  </button>
                ) : (
                  <div className={styles.modelPickerGroupHeader} data-fixed="true">
                    <span>{group.label}</span>
                  </div>
                )}
                {expanded && (
                  <div id={groupOptionsId} className={styles.modelPickerGroupOptions} role="group" aria-label={group.label}>
                    {group.models.map((model) => {
                      const selectedModel = value === model.id;
                      return (
                        <button
                          type="button"
                          className={styles.modelPickerOption}
                          key={model.id}
                          role="option"
                          aria-selected={selectedModel}
                          onClick={() => chooseModel(model.id)}
                        >
                          <span className={styles.modelPickerOptionLabel}>{modelOptionLabel(model)}</span>
                          {selectedModel && <Check className={styles.modelPickerOptionCheck} size={15} aria-hidden="true" />}
                        </button>
                      );
                    })}
                  </div>
                )}
              </section>
            );
          })}
        </div>
      )}
    </div>
  );
}
