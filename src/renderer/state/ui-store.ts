import { create } from "zustand";
import type { UiSlice } from "./types";

export const useUiStore = create<UiSlice>((set) => ({
  route: "projects",
  theme: "system",
  density: "comfortable",
  sidebarCollapsed: false,
  toast: null,
  dialog: null,
  settingsSection: null,
  settingsSectionRequest: 0,
  setRoute: (route) => set({ route }),
  setTheme: (theme) => set({ theme }),
  setDensity: (density) => set({ density }),
  // Selecting the same anchor is still a new scroll/focus request.
  setSettingsSection: (settingsSection) => set((state) => ({ settingsSection, settingsSectionRequest: state.settingsSectionRequest + 1 })),
  hydrateAppearance: (appearance) => set(appearance),
  toggleSidebar: () => set((state) => ({ sidebarCollapsed: !state.sidebarCollapsed })),
  setToast: (toast) => set({ toast }),
  setDialog: (dialog) => set({ dialog }),
}));
