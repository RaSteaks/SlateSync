import type { Meta, StoryObj } from "@storybook/react-vite";
import { AlertTriangle, CheckCircle2, FileText, Moon, Plus, Sun } from "lucide-react";
import { useEffect, useState, type MouseEvent } from "react";
import { Badge, Button, Checkbox, Dialog, EmptyState, Field, Icon, IconButton, InlineError, Input, Progress, SegmentedControl, Select, Spinner, Stack, StatusIndicator, Surface, Text, Textarea } from "./index";

const meta = { title: "Foundations / Controls", component: Button, tags: ["autodocs"] } satisfies Meta<typeof Button>;
export default meta;
type Story = StoryObj<typeof meta>;

// Static stories keep their sample controls focusable and genuinely actionable
// without pretending to perform a product mutation.
const focusStoryControl = (event: MouseEvent<HTMLButtonElement>) => event.currentTarget.focus();

export const Controls: Story = {
  render: () => <Stack gap={5}><Stack direction="row" gap={3} align="center" wrap><Button onClick = {focusStoryControl} startIcon={<Plus size={15} />}>开始识别</Button><Button onClick = {focusStoryControl} variant="secondary">次要操作</Button><Button onClick = {focusStoryControl} variant="ghost">轻操作</Button><Button onClick = {focusStoryControl} variant="danger">删除</Button><IconButton label="切换主题" onClick = {focusStoryControl}><Moon size={17} /></IconButton></Stack><Stack direction="row" gap={4} wrap><Field label="Provider" hint="密钥不会回显"><Select defaultValue="openai"><option value="openai">OpenAI · 已配置</option><option value="openrouter">OpenRouter</option></Select></Field><Field label="项目提示"><Textarea className="resize-none" rows={2} placeholder="输入辅助说明" /></Field><Field label="搜索"><Input placeholder="卡号 / 视频码" /></Field></Stack><Stack direction="row" gap={3} align="center"><Checkbox label="保留页面顺序" defaultChecked /><SegmentedControl label="密度" value="compact" options={[{ value: "compact", label: "紧凑" }, { value: "comfortable", label: "标准" }]} onChange={() => undefined} /></Stack></Stack>,
};

export const Feedback: Story = {
  render: () => <Stack gap={4}><Stack direction="row" gap={2} wrap><Badge tone="accent">进行中</Badge><Badge tone="success" icon={CheckCircle2}>已完成</Badge><Badge tone="warning" icon={AlertTriangle}>需复核</Badge><StatusIndicator tone="danger" label="失败" /></Stack><Progress value={62} label="识别进度" /><Stack direction="row" gap={3} align="center"><Spinner label="正在识别" /><Text tone="muted" size="sm">准备第 3 / 4 页</Text></Stack><InlineError message="Provider 暂时不可用，请检查密钥或稍后重试。" onRetry={() => undefined} /></Stack>,
};

export const StateMatrix: Story = {
  render: () => <div data-theme="light" data-density="compact"><Stack gap={5}><Text as="h2" size="lg" weight="bold">Light / compact interaction states</Text><Stack direction="row" gap={2} wrap><Button onClick = {focusStoryControl} autoFocus>Focus / hover</Button><Button disabled>Disabled</Button><Button disabled loading>Loading</Button><Button onClick = {focusStoryControl} variant="danger">Danger</Button></Stack><Field label="Long text" hint="焦点环、placeholder 与辅助说明使用同一语义边界"><Input placeholder="这是一个较长的输入提示，用于检查窄屏与高密度下的截断行为" /></Field><InlineError message="这是一个可恢复错误状态；操作应保留上下文并给出下一步。" onRetry={() => undefined} /><Surface><EmptyState title="空状态" description="Empty state 保持可读、可聚焦，并在 reduced-motion 下不依赖动画。" action={<Button onClick = {focusStoryControl} variant="secondary">开始添加</Button>} /></Surface></Stack></div>,
};

export const SegmentedStates: Story = {
  render: function Render() {
    const [theme, setTheme] = useState<"light" | "dark">("light");
    const [density, setDensity] = useState<"comfortable" | "compact">("comfortable");
    useEffect(() => {
      // Runtime tokens are rooted on html. Restore the previous attributes so
      // this interactive contrast story does not recolor subsequent stories.
      const root = document.documentElement;
      const previousTheme = root.getAttribute("data-theme");
      const previousDensity = root.getAttribute("data-density");
      root.dataset.theme = theme;
      root.dataset.density = density;
      return () => {
        if (previousTheme === null) root.removeAttribute("data-theme"); else root.setAttribute("data-theme", previousTheme);
        if (previousDensity === null) root.removeAttribute("data-density"); else root.setAttribute("data-density", previousDensity);
      };
    }, [theme, density]);
    return <Stack gap={4}>
      <Text as="h2" size="lg" weight="bold">分段按钮状态</Text>
      <Text tone="muted" size="sm">切换主题和密度，检查未选中、选中、悬停、键盘焦点和禁用状态。</Text>
      <Stack direction="row" wrap><SegmentedControl label="主题" value={theme} options={[{ value: "light", label: "浅色" }, { value: "dark", label: "深色" }]} onChange={setTheme} /></Stack>
      <Stack direction="row" wrap><SegmentedControl label="信息密度" value={density} options={[{ value: "comfortable", label: "标准" }, { value: "compact", label: "紧凑" }]} onChange={setDensity} /></Stack>
      <Stack direction="row" wrap><SegmentedControl label="禁用的信息密度" disabled value={density} options={[{ value: "comfortable", label: "标准" }, { value: "compact", label: "紧凑" }]} onChange={setDensity} /></Stack>
    </Stack>;
  },
};

export const Empty: Story = { render: () => <Surface><EmptyState icon={FileText} title="没有载入 CSV" description="选择 Resolve 导出的 CSV 后，这里会显示虚拟化预览。" action={<Button onClick = {focusStoryControl}>载入文件</Button>} /></Surface> };

export const DialogAndThemes: Story = {
  render: function Render() {
    const [open, setOpen] = useState(false);
    const [theme, setTheme] = useState<"dark" | "light">("dark");
    return <div data-theme={theme}><Stack direction="row" gap={3}><Button onClick={() => setOpen(true)}>打开对话框</Button><Button variant="ghost" onClick={() => setTheme(theme === "dark" ? "light" : "dark")} startIcon={theme === "dark" ? <Sun size={15} /> : <Moon size={15} />}>切换主题</Button></Stack><Dialog open={open} title="创建项目" description="键盘焦点会保留在对话框内，Escape 可关闭。" onClose={() => setOpen(false)} footer={<Button onClick={() => setOpen(false)}>完成</Button>}><Text tone="muted">这是 Overlay 的焦点恢复、Escape 与 aria-modal 状态。</Text></Dialog></div>;
  },
};
