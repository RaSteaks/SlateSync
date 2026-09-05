import { Check, ChevronDown, ChevronRight } from "lucide-react";
import { useEffect, useId, useMemo, useRef, useState } from "react";
import { flushSync } from "react-dom";
import { Button as AriaButton, Dialog as AriaDialog, Popover, Tree, TreeHeader, TreeItem, TreeItemContent, TreeSection } from "react-aria-components";
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

/** The maintained Tree owns focus, typeahead and hierarchical selection. The
 * popup is a dialog because React Aria's Tree has treegrid semantics.
 * Only leaf activation commits; browsing or dismissing preserves the value. */
export function ModelSelect({ value, groups, onChange, placeholder, disabled = false, id, "aria-describedby": describedBy, "aria-invalid": invalid, "data-state": dataState }: ModelSelectProps) {
  const [open, setOpen] = useState(false);
  const [expanded, setExpanded] = useState<Set<string>>(() => new Set());
  const triggerRef = useRef<HTMLButtonElement>(null);
  const popupRef = useRef<HTMLElement>(null);
  const openRef = useRef(false);
  const popupId = useId();
  const catalogIdentity = groups.map((group) => `${group.key}:${group.models.map((model) => model.id).join(",")}`).join("|");
  const selected = useMemo(() => {
    for (const group of groups) {
      const model = group.models.find((candidate) => candidate.id === value);
      if (model) return { model, group, key: `${group.key}:${model.id}` };
    }
    return null;
  }, [groups, value]);
  const leaves = useMemo(() => new Map<string, string>(groups.flatMap((group) => group.models.map((model) => [`${group.key}:${model.id}`, model.id] as const))), [groups]);
  const groupKeys = groups.filter((group) => group.collapsible).map((group) => group.key);

  const changeOpen = (next: boolean) => {
    if (next && disabled) return;
    if (next && selected?.group.collapsible) setExpanded((keys) => new Set(keys).add(selected.group.key));
    openRef.current = next;
    setOpen(next);
  };
  const closeAndRestore = () => {
    // Remove the popover's focus scope before restoring the form position.
    // Otherwise focus containment redirects the trigger focus into the tree.
    flushSync(() => changeOpen(false));
    if (!triggerRef.current?.disabled) triggerRef.current?.focus({ preventScroll: true });
  };
  const choose = (key: string) => {
    const modelId = leaves.get(key);
    if (!openRef.current || disabled || !modelId) return;
    // Close synchronously so one activation cannot submit twice.
    openRef.current = false;
    setOpen(false);
    onChange(modelId);
    // The popover restores focus after the press has finished. Moving focus
    // during Enter's keydown would send its native click to the trigger.
  };

  useEffect(() => {
    // Provider/catalog changes invalidate every previously visible option.
    openRef.current = false;
    setOpen(false);
  }, [disabled, catalogIdentity]);

  const label = selected ? modelOptionLabel(selected.model) : value ? `${value} · 已保存（当前未加载）` : placeholder;
  const renderModel = (group: ModelOptionGroup, model: ModelOptionGroup["models"][number]) => {
    const key = `${group.key}:${model.id}`;
    return <TreeItem key={key} id={key} textValue={modelOptionLabel(model)} className={styles.modelPickerOption || ""}>
      <TreeItemContent>
        <span className={styles.modelPickerOptionLabel || ""}>{modelOptionLabel(model)}</span>
        {value === model.id && <Check className={styles.modelPickerOptionCheck || ""} size={15} aria-hidden="true" />}
      </TreeItemContent>
    </TreeItem>;
  };

  return <div className={styles.modelPicker || ""} onClick={(event) => event.stopPropagation()}
      onKeyDownCapture={(event) => {
        if (!openRef.current || !popupRef.current?.contains(event.target as Node) || event.nativeEvent.isComposing) return;
        if (event.key === "Escape") {
          event.preventDefault(); event.stopPropagation(); closeAndRestore();
        } else if (event.key === "Tab") {
          // Restore the logical form position before native Tab. The body
          // portal escapes scrolling dialogs without changing tab order.
          closeAndRestore();
          event.stopPropagation();
        }
      }}>
    <AriaButton
      ref={triggerRef} {...(id ? { id } : {})} className={styles.modelPickerTrigger || ""} isDisabled={disabled}
      data-open={open || undefined} data-state={dataState} {...(describedBy ? { "aria-describedby": describedBy } : {})}
      {...(invalid === undefined ? {} : { "aria-invalid": invalid })} aria-expanded={open} aria-haspopup="dialog" {...(open ? { "aria-controls": popupId } : {})}
      onPress={() => changeOpen(!openRef.current)}
      onKeyDown={(event) => {
        if (event.nativeEvent.isComposing) return;
        if (event.key === "ArrowDown" || event.key === "ArrowUp") { event.preventDefault(); changeOpen(true); }
      }}
    >
      <span className={styles.modelPickerTriggerLabel || ""} data-placeholder={!value || undefined}>{label}</span>
      <ChevronDown className={styles.modelPickerTriggerIcon || ""} size={16} aria-hidden="true" />
    </AriaButton>
    <Popover
      ref={popupRef} isOpen={open} onOpenChange={changeOpen} triggerRef={triggerRef}
      placement="bottom start" offset={6} containerPadding={12} maxHeight={440}
      className={styles.modelPickerMenu || ""}
      style={{ width: "var(--trigger-width)", boxSizing: "border-box", zIndex: "calc(var(--ss-z-overlay) + 1)" }}
    >
      <AriaDialog id={popupId} aria-label="选择模型" className={styles.modelPickerTreeDialog || ""}>
        <Tree
          aria-label="模型列表" className={styles.modelPickerTree || ""} autoFocus="first"
          selectionMode="single" selectionBehavior="toggle" escapeKeyBehavior="none"
          selectedKeys={selected ? [selected.key] : []} disabledKeys={groupKeys} disabledBehavior="selection"
          expandedKeys={expanded} onExpandedChange={(keys) => setExpanded(new Set([...keys].map(String)))}
          onSelectionChange={(keys) => {
            if (keys === "all") return;
            // Toggle selection keeps arrow/typeahead focus separate from the
            // committed value. React Aria emits an empty set when the current
            // leaf is activated again; that confirms the same value here.
            const key = [...keys][0] ?? selected?.key;
            if (key !== undefined) choose(String(key));
          }}
          renderEmptyState={() => <div className={styles.modelPickerEmpty || ""}>暂无可用模型</div>}
        >
          {groups.map((group) => <TreeSection key={group.key} className={styles.modelPickerGroup || ""} aria-label={group.label}>
            {group.collapsible ? <TreeItem id={group.key} textValue={group.label} className={styles.modelPickerGroupHeader || ""}>
              <TreeItemContent>
                <AriaButton slot="chevron" className={styles.modelPickerGroupToggle || ""} aria-label={group.label}>
                  <ChevronRight className={styles.modelPickerGroupHeaderIcon || ""} size={14} aria-hidden="true" />
                  <span>{group.label}</span>
                </AriaButton>
              </TreeItemContent>
              {group.models.map((model) => renderModel(group, model))}
            </TreeItem> : <>
              <TreeHeader className={styles.modelPickerGroupHeader || ""} data-fixed="true">{group.label}</TreeHeader>
              {group.models.map((model) => renderModel(group, model))}
            </>}
          </TreeSection>)}
        </Tree>
      </AriaDialog>
    </Popover>
  </div>;
}
