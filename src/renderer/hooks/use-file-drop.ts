import { useState, type DragEvent } from "react";

/**
 * Shared drag state keeps file drop behavior consistent while every drop zone
 * retains its regular button/input alternative for keyboard users.
 */
export function useFileDrop({
  disabled = false,
  onFile,
}: {
  readonly disabled?: boolean;
  readonly onFile: (file: File) => void | Promise<void>;
}) {
  const [dragging, setDragging] = useState(false);

  return {
    dragging,
    dropProps: {
      onDragEnter: (event: DragEvent<HTMLElement>) => {
        event.preventDefault();
        if (!disabled) setDragging(true);
      },
      onDragOver: (event: DragEvent<HTMLElement>) => {
        event.preventDefault();
        if (!disabled) setDragging(true);
      },
      onDragLeave: (event: DragEvent<HTMLElement>) => {
        if (event.relatedTarget instanceof Node && event.currentTarget.contains(event.relatedTarget)) return;
        setDragging(false);
      },
      onDrop: (event: DragEvent<HTMLElement>) => {
        event.preventDefault();
        setDragging(false);
        if (disabled) return;
        const file = event.dataTransfer.files?.[0];
        if (file) void onFile(file);
      },
    },
  };
}
