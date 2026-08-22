import {
  AlertTriangle,
  Check,
  CircleHelp,
  Info,
  LoaderCircle,
  X,
  type LucideIcon,
} from "lucide-react";
import {
  forwardRef,
  useLayoutEffect,
  useId,
  useRef,
  cloneElement,
  isValidElement,
  type ButtonHTMLAttributes,
  type ComponentPropsWithoutRef,
  type ElementType,
  type HTMLAttributes,
  type InputHTMLAttributes,
  type ReactElement,
  type ReactNode,
  type SelectHTMLAttributes,
  type TextareaHTMLAttributes,
} from "react";
import { createPortal } from "react-dom";
import styles from "./components.module.css";

type Tone = "neutral" | "accent" | "success" | "warning" | "danger";
type ClassProps = { className?: string };

function classes(...values: Array<string | false | null | undefined>) {
  return values.filter(Boolean).join(" ");
}

export function Surface({ as: Component = "div", tone = "neutral", compact = false, className, ...props }: HTMLAttributes<HTMLElement> & { as?: ElementType; tone?: Tone; compact?: boolean }) {
  return <Component className={classes(styles.surface, tone === "accent" && styles.surfaceAccent, tone === "danger" && styles.surfaceDanger, compact && styles.surfaceCompact, className)} {...props} />;
}

export function Stack({ direction = "column", gap = 4, align, justify, wrap = false, className, ...props }: HTMLAttributes<HTMLDivElement> & { direction?: "row" | "column"; gap?: 1 | 2 | 3 | 4 | 5 | 6 | 8; align?: "start" | "center" | "end" | "stretch"; justify?: "between" | "center" | "end"; wrap?: boolean }) {
  return <div className={classes(styles.stack, className)} data-direction={direction} data-gap={gap} data-align={align} data-justify={justify} data-wrap={wrap || undefined} {...props} />;
}

export function Text({ as: Component = "p", tone = "neutral", size = "md", weight, mono = false, className, ...props }: HTMLAttributes<HTMLElement> & { as?: ElementType; tone?: "neutral" | "muted" | "subtle" | "accent" | "danger" | "warning" | "success"; size?: "xs" | "sm" | "md" | "lg" | "xl"; weight?: "medium" | "bold"; mono?: boolean }) {
  return <Component className={classes(styles.text, className)} data-tone={tone} data-size={size} data-weight={weight} data-mono={mono || undefined} {...props} />;
}

export function Icon({ icon: IconComponent, label, size = 18, className }: { icon: LucideIcon; label?: string; size?: number; className?: string }) {
  return <IconComponent className={classes(styles.icon, className)} size={size} aria-label={label} aria-hidden={label ? undefined : true} focusable="false" />;
}

export function Separator({ className, ...props }: HTMLAttributes<HTMLHRElement>) {
  return <hr className={classes(styles.separator, className)} {...props} />;
}

type ButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & { variant?: "primary" | "secondary" | "ghost" | "danger"; size?: "sm" | "md" | "lg"; loading?: boolean; startIcon?: ReactNode; endIcon?: ReactNode };
export const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button({ variant = "secondary", size = "md", loading = false, disabled, startIcon, endIcon, children, ...props }, ref) {
  return <button ref={ref} className={styles.button} data-variant={variant} data-size={size} disabled={disabled || loading} aria-busy={loading || undefined} {...props}>
    {loading ? <LoaderCircle className={styles.spinner} size={16} aria-hidden="true" /> : startIcon}
    <span>{children}</span>
    {!loading && endIcon}
  </button>;
});

export const IconButton = forwardRef<HTMLButtonElement, ButtonHTMLAttributes<HTMLButtonElement> & { label: string; size?: "sm" | "md" }>(function IconButton({ label, size = "md", children, ...props }, ref) {
  return <button ref={ref} className={styles.iconButton} data-size={size} aria-label={label} {...props}>{children}</button>;
});

export const Input = forwardRef<HTMLInputElement, InputHTMLAttributes<HTMLInputElement> & ClassProps>(function Input({ className, ...props }, ref) {
  return <input ref={ref} className={classes(styles.control, className)} {...props} />;
});

export const Textarea = forwardRef<HTMLTextAreaElement, TextareaHTMLAttributes<HTMLTextAreaElement> & ClassProps>(function Textarea({ className, ...props }, ref) {
  return <textarea ref={ref} className={classes(styles.control, styles.textarea, className)} {...props} />;
});

export const Select = forwardRef<HTMLSelectElement, SelectHTMLAttributes<HTMLSelectElement> & ClassProps>(function Select({ className, ...props }, ref) {
  return <select ref={ref} className={classes(styles.control, className)} {...props} />;
});

export function Field({ label, hint, error, children, htmlFor }: { label: string; hint?: string | undefined; error?: string | undefined; children: ReactNode; htmlFor?: string | undefined }) {
  const generatedId = useId();
  const id = htmlFor || generatedId;
  const hintId = hint ? `${id}-hint` : undefined;
  const errorId = error ? `${id}-error` : undefined;
  const describedBy = [hintId, errorId].filter((value): value is string => Boolean(value)).join(" ") || undefined;
  // Field owns the label/control relationship so every design-system input
  // remains accessible even when a feature omits a manual htmlFor id.
  const control = isValidElement(children)
    ? cloneElement(children as ReactElement<{ id?: string; "aria-describedby"?: string; "aria-invalid"?: boolean }>, { id, ...(describedBy ? { "aria-describedby": describedBy } : {}), ...(error ? { "aria-invalid": true } : {}) })
    : children;
  return <label htmlFor={id}>
    <span className={styles.fieldLabel}>{label}</span>
    {control}
    {hint && <span className={styles.fieldHint} id={hintId}>{hint}</span>}
    {error && <span className={styles.fieldHint} id={errorId} role="alert" data-tone="danger">{error}</span>}
  </label>;
}

export function Checkbox({ label, ...props }: InputHTMLAttributes<HTMLInputElement> & { label: string }) {
  return <label className={styles.checkbox}><input type="checkbox" {...props} /><span>{label}</span></label>;
}

export function SegmentedControl<T extends string>({ value, options, onChange, label }: { value: T; options: readonly { value: T; label: string }[]; onChange: (value: T) => void; label: string }) {
  return <div className={styles.segmented} role="group" aria-label={label}>{options.map((option) => <button key={option.value} type="button" className={styles.segmentedButton} data-active={value === option.value} aria-pressed={value === option.value} onClick={() => onChange(option.value)}>{option.label}</button>)}</div>;
}

export function Badge({ tone = "neutral", children, icon: IconComponent }: { tone?: Tone; children: ReactNode; icon?: LucideIcon }) {
  return <span className={styles.badge} data-tone={tone}>{IconComponent && <Icon icon={IconComponent} size={13} />} {children}</span>;
}

export function StatusIndicator({ tone = "neutral", label }: { tone?: Tone; label: string }) {
  return <span className={styles.badge} data-tone={tone}><span className={styles.statusDot} aria-hidden="true" />{label}</span>;
}

export function Spinner({ label = "处理中" }: { label?: string }) {
  return <span role="status" aria-label={label}><LoaderCircle className={styles.spinner} size={18} aria-hidden="true" /></span>;
}

export function Progress({ value, label }: { value: number; label: string }) {
  const safeValue = Math.min(100, Math.max(0, Math.round(value)));
  return <div>
    <div className={styles.progress} role="progressbar" aria-label={label} aria-valuemin={0} aria-valuemax={100} aria-valuenow={safeValue}><div className={styles.progressBar} style={{ width: `${safeValue}%` }} /></div>
  </div>;
}

export function InlineError({ message, onRetry }: { message: string; onRetry?: () => void }) {
  return <div className={styles.inlineError} role="alert"><AlertTriangle size={17} aria-hidden="true" /><span>{message}</span>{onRetry && <Button size="sm" variant="ghost" onClick={onRetry}>重试</Button>}</div>;
}

export function EmptyState({ icon: IconComponent = CircleHelp, title, description, action }: { icon?: LucideIcon; title: string; description?: string; action?: ReactNode }) {
  return <div className={styles.emptyState}><div><div className={styles.emptyIcon}><Icon icon={IconComponent} /></div><Text as="h2" size="lg" weight="bold">{title}</Text>{description && <Text tone="muted" size="sm">{description}</Text>}{action && <div style={{ marginTop: "var(--ss-space-4)" }}>{action}</div>}</div></div>;
}

export function Toast({ message, tone = "neutral", onDismiss }: { message: string; tone?: Tone; onDismiss?: () => void }) {
  return <div className={styles.toast} role="status" aria-live="polite"><Stack direction="row" gap={3} align="center"><StatusIndicator tone={tone} label={message} />{onDismiss && <IconButton label="关闭通知" size="sm" onClick={onDismiss}><X size={16} /></IconButton>}</Stack></div>;
}

export function Dialog({ open, title, description, onClose, children, footer }: { open: boolean; title: string; description?: string; onClose: () => void; children: ReactNode; footer?: ReactNode }) {
  const dialogRef = useRef<HTMLDivElement>(null);
  const restoreRef = useRef<HTMLElement | null>(null);
  const onCloseRef = useRef(onClose);
  const wasOpenRef = useRef(false);
  const titleId = useId();
  onCloseRef.current = onClose;
  if (open && !wasOpenRef.current) {
    // Capture before portal children commit: a descendant autoFocus can move
    // document.activeElement to an input before the layout effect executes.
    restoreRef.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
  }
  wasOpenRef.current = open;
  useLayoutEffect(() => {
    if (!open) {
      // The portal is already absent in this layout phase, so restoring here
      // avoids both browser body-focus fallback and stale portal descendants.
      const opener = restoreRef.current;
      if (opener?.isConnected) opener.focus();
      return undefined;
    }
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    const focusable = () => dialogRef.current?.querySelector<HTMLElement>("button, [href], input, select, textarea, [tabindex]:not([tabindex='-1'])");
    focusable()?.focus();
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") { event.preventDefault(); onCloseRef.current(); return; }
      if (event.key !== "Tab" || !dialogRef.current) return;
      const nodes = [...dialogRef.current.querySelectorAll<HTMLElement>("button, [href], input, select, textarea, [tabindex]:not([tabindex='-1'])")].filter((node) => !node.hasAttribute("disabled"));
      if (!nodes.length) return;
      const first = nodes[0];
      const last = nodes[nodes.length - 1];
      if (!first || !last) return;
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
    };
    document.addEventListener("keydown", onKeyDown);
    return () => {
      document.removeEventListener("keydown", onKeyDown);
      document.body.style.overflow = previousOverflow;
    };
  }, [open]);
  if (!open) return null;
  return createPortal(<div className={styles.dialogOverlay} role="presentation" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }}>
    <div ref={dialogRef} className={styles.dialog} role="dialog" aria-modal="true" aria-labelledby={titleId}>
      <div className={styles.dialogHeader}><div><Text as="h2" id={titleId} size="lg" weight="bold">{title}</Text>{description && <Text tone="muted" size="sm">{description}</Text>}</div><IconButton label="关闭对话框" onClick={onClose}><X size={18} /></IconButton></div>
      {children}
      {footer && <><Separator /><div style={{ marginTop: "var(--ss-space-5)" }}>{footer}</div></>}
    </div>
  </div>, document.body);
}

export function Popover({ open, children, className }: { open: boolean; children: ReactNode; className?: string }) {
  if (!open) return null;
  return <div className={classes(styles.popover, className)} role="dialog">{children}</div>;
}

export function Tooltip({ label, children }: { label: string; children: ReactNode }) {
  const tooltipId = useId();
  return <span className={styles.tooltipWrap} aria-describedby={tooltipId}>{children}<span id={tooltipId} className={styles.tooltipLabel} role="tooltip">{label}</span></span>;
}

export function ContextMenu({ open, children, style }: { open: boolean; children: ReactNode; style?: ComponentPropsWithoutRef<"div">["style"] }) {
  if (!open) return null;
  return <div className={styles.contextMenu} style={style} role="menu">{children}</div>;
}

export function AppShell({ sidebar, toolbar, children, collapsed = false }: { sidebar: ReactNode; toolbar: ReactNode; children: ReactNode; collapsed?: boolean }) {
  return <div className={styles.appShell} data-collapsed={collapsed || undefined}><aside className={styles.sidebar}>{sidebar}</aside><div className={styles.main}><header className={styles.toolbar}>{toolbar}</header>{children}</div></div>;
}

export function Sidebar({ brand, navigation, footer }: { brand: ReactNode; navigation: ReactNode; footer?: ReactNode }) {
  return <><div className={styles.brand}>{brand}</div><nav aria-label="主导航">{navigation}</nav>{footer && <div className={styles.sidebarFooter}>{footer}</div>}</>;
}

export function Toolbar({ title, subtitle, actions }: { title: string; subtitle?: string; actions?: ReactNode }) {
  return <><div className={styles.toolbarTitle}><strong>{title}</strong>{subtitle && <small>{subtitle}</small>}</div>{actions && <div className={styles.toolbarActions}>{actions}</div>}</>;
}

export function Panel({ children, className, ...props }: HTMLAttributes<HTMLDivElement> & ClassProps) {
  return <div className={classes(styles.panel, className)} {...props}>{children}</div>;
}

export function SplitPane({ children, className }: { children: ReactNode; className?: string }) {
  return <div className={classes(styles.splitPane, className)}>{children}</div>;
}

export { Check, Info };
