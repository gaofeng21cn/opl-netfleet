// The AppKit host hands its system accent to the page before the bundle runs.
// The page owns the tint ramp the shared design tokens expect.

declare global {
  interface Window { __netfleetHostAccent?: string }
}

export interface HostAccentTokens {
  accent: string;
  strong: string;
  soft: string;
  border: string;
  foreground: string;
}

type Rgb = { r: number; g: number; b: number };

const WHITE: Rgb = { r: 255, g: 255, b: 255 };
const BLACK: Rgb = { r: 0, g: 0, b: 0 };

const clamp = (value: number) => Math.min(255, Math.max(0, Math.round(value)));

function parse(value: string): Rgb | null {
  const match = /^#?([0-9a-f]{6})$/i.exec(value.trim());
  if (!match) return null;
  const color = Number.parseInt(match[1], 16);
  return { r: (color >> 16) & 255, g: (color >> 8) & 255, b: color & 255 };
}

const toHex = (color: Rgb) => `#${[color.r, color.g, color.b].map(channel => clamp(channel).toString(16).padStart(2, '0')).join('')}`;
const mix = (color: Rgb, target: Rgb, ratio: number): Rgb => ({
  r: color.r + (target.r - color.r) * ratio,
  g: color.g + (target.g - color.g) * ratio,
  b: color.b + (target.b - color.b) * ratio,
});

const luminance = (color: Rgb) => {
  const channel = (value: number) => {
    const scaled = value / 255;
    return scaled <= 0.03928 ? scaled / 12.92 : ((scaled + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b);
};

export function hostAccentTokens(input: string | null | undefined): HostAccentTokens | null {
  const color = input ? parse(input) : null;
  if (!color) return null;
  return {
    accent: toHex(color),
    strong: toHex(mix(color, BLACK, 0.16)),
    soft: toHex(mix(color, WHITE, 0.9)),
    border: toHex(mix(color, WHITE, 0.55)),
    // Filled accent surfaces keep their label readable for light system accents.
    foreground: luminance(color) > 0.6 ? '#000000' : '#ffffff',
  };
}

export function applyHostAccent(accent: string | null | undefined, target: HTMLElement = document.documentElement): boolean {
  const tokens = hostAccentTokens(accent);
  if (!tokens) return false;
  target.style.setProperty('--nf-host-accent', tokens.accent);
  target.style.setProperty('--nf-host-accent-strong', tokens.strong);
  target.style.setProperty('--nf-host-accent-soft', tokens.soft);
  target.style.setProperty('--nf-host-accent-border', tokens.border);
  target.style.setProperty('--nf-host-accent-foreground', tokens.foreground);
  return true;
}
