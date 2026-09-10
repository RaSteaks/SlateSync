import { useState } from "react";
import { createRoot } from "react-dom/client";
import { ModelSelect } from "../../src/renderer/features/recognition/ModelSelect";
import { Dialog, Field, Input } from "../../src/renderer/design-system";

// Browser-only fixture uses production primitives to check nested Escape/Tab.
const groups = [
  { key: "fixed", label: "推荐", models: ["Alpha", "Beta"].map(id => ({ id, label: id, description: "", providers: ["test"] })) },
  { key: "vendor", label: "更多模型", collapsible: true, models: ["Gamma", "Delta"].map(id => ({ id, label: id, description: "", providers: ["test"] })) },
];
function Harness() {
  const [value, setValue] = useState("Alpha");
  const [open, setOpen] = useState(true);
  return <Dialog open={open} title="键盘测试" onClose={() => setOpen(false)}>
    <Field label="模型"><ModelSelect value={value} groups={groups} onChange={setValue} placeholder="选择模型" /></Field>
    <Field label="后续输入"><Input /></Field>
  </Dialog>;
}
export function mount() {
  const host = document.createElement("div"); host.id = "picker-harness"; document.body.append(host);
  createRoot(host).render(<Harness />);
}
