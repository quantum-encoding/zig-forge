/**
 * ZigPDF Quote Generator Types
 *
 * Type definitions for the CRG Direct quote PDF generator.
 */

// ============================================================================
// Quote Data Types
// ============================================================================

export interface CustomerInfo {
  name: string;
  address: string;
  postcode?: string;
  email?: string;
  phone?: string;
}

export interface SolarSystem {
  panels: string;           // e.g., "12 x JA Solar 440W All-Black Panels"
  size: string;             // e.g., "5.28kWp"
  inverter: string;         // e.g., "GivEnergy 5.0kW Hybrid Inverter"
  orientation: string;      // e.g., "South-facing"
  pitch: string;            // e.g., "35°"
  yield: string;            // e.g., "4,800 kWh"
  price: number;
}

export interface BatterySystem {
  model: string;            // e.g., "GivEnergy 9.5kWh Battery"
  capacity: string;         // e.g., "9.5kWh usable capacity"
  warranty: string;         // e.g., "10 year manufacturer warranty"
  features: string[];
  price: number;
}

export interface HeatPumpSystem {
  model: string;
  output: string;
  scop: string;
  features: string[];
  price: number;
}

export interface EVChargerSystem {
  model: string;
  power: string;
  features: string[];
  price: number;
}

export interface SystemConfig {
  solar?: SolarSystem;
  battery?: BatterySystem;
  heatPump?: HeatPumpSystem;
  evCharger?: EVChargerSystem;
  installation?: string[];
}

export interface LineItem {
  description: string;
  amount: number;
}

export interface SavingsEstimate {
  year1: number;
  lifetime: number;
  paybackYears: number;
  co2Tonnes: number;
}

export interface CompanyInfo {
  name?: string;
  legalName?: string;
  address?: string;
  phone?: string;
  email?: string;
  website?: string;
  companyReg?: string;
  vatNumber?: string;
  mcsNumber?: string;
  tagline?: string;
  colors?: BrandColors;
  accreditations?: string[];
  stats?: CompanyStats;
}

export interface BrandColors {
  primary: string;
  primaryDark: string;
  primaryDarker: string;
  primaryDarkest: string;
  dark: string;
  darkMid: string;
  darkLight: string;
  gray: string;
  grayLight: string;
  grayLighter: string;
  background: string;
  backgroundGreen: string;
  backgroundGreenLight: string;
  border: string;
  borderGreen: string;
  white: string;
  success: string;
  accent: string;
}

export interface CompanyStats {
  installations: string;
  rating: string;
  experience: string;
  warranty: string;
}

export interface QuoteData {
  customer: CustomerInfo;
  quoteRef: string;
  date: string;
  validUntil: string;
  advisor: string;
  system: SystemConfig;
  lineItems: LineItem[];
  savings: SavingsEstimate;
  company?: CompanyInfo;
}

// ============================================================================
// PDF Template Types
// ============================================================================

export interface PageSize {
  width: number;
  height: number;
}

export interface TextElement {
  type: 'text';
  content: string;
  x: number;
  y: number;
  font_size?: number;
  font_weight?: 'normal' | 'bold';
  font_style?: 'normal' | 'italic';
  color?: string;
  align?: 'left' | 'center' | 'right';
  max_width?: number;
  line_height?: number;
}

export interface BulletListElement {
  type: 'bullet_list';
  items: string[];
  x: number;
  y: number;
  font_size?: number;
  color?: string;
  bullet_color?: string;
  line_spacing?: number;
  indent?: number;
}

export interface TableElement {
  type: 'table';
  x: number;
  y: number;
  columns: string[];
  column_widths?: number[];
  rows: string[][];
  header_bg_color?: string;
  header_text_color?: string;
  row_bg_color?: string;
  alt_row_bg_color?: string;
  text_color?: string;
  border_color?: string;
  font_size?: number;
  header_font_size?: number;
  padding?: number;
  row_height?: number;
  header_height?: number;
}

export interface ShapeElement {
  type: 'shape';
  shape: 'rectangle' | 'line' | 'circle' | 'ellipse';
  x: number;
  y: number;
  width: number;
  height: number;
  fill_color?: string | null;
  stroke_color?: string;
  stroke_width?: number;
}

export interface ImageElement {
  type: 'image';
  base64: string;
  x: number;
  y: number;
  width: number;
  height: number;
  maintain_aspect?: boolean;
}

export type PresentationElement =
  | TextElement
  | BulletListElement
  | TableElement
  | ShapeElement
  | ImageElement;

export interface PresentationPage {
  background_color?: string;
  elements: PresentationElement[];
}

export interface PresentationTemplate {
  page_size: PageSize;
  pages: PresentationPage[];
}

// ============================================================================
// WASM Module Types
// ============================================================================

export interface ZigPdfModule {
  generatePresentation: (jsonString: string) => Uint8Array;
  generateInvoice: (jsonString: string) => Uint8Array;
  generateLetterQuote: (jsonString: string) => Uint8Array;
  getVersion: () => string;
  getLastError: () => string | null;
}

// ============================================================================
// Letter Quote Types (premium Word-document-style template)
// ============================================================================
// Mirrors src/letter_quote.zig. Serialise with JSON.stringify and pass to
// ZigPdfModule.generateLetterQuote. See templates/LETTER_QUOTE_GUIDE.md for
// the full schema and styling conventions.

export interface LetterQuoteCompany {
  name: string;
  phone?: string;
  email?: string;
}

export interface LetterQuoteStyle {
  /** Hex colour for the title, labels, and section headings. Default #1a2a5e. */
  primary_color?: string;
  /** Hex colour for the gold hairlines and the TOTAL row. Default #e8a83d. */
  accent_color?: string;
  /** "montserrat" (recommended) or "helvetica" (smaller binary). */
  font_family?: 'montserrat' | 'helvetica';
  /** Filesystem path OR "data:image/png;base64,..." data URL. Optional. */
  watermark_image?: string;
  /** 0.0–1.0. Default 0.08 (very faint). */
  watermark_opacity?: number;
  /** Fraction of page width. Default 0.60. */
  watermark_scale?: number;
}

export interface LetterQuoteHeadingBlock {
  type: 'heading';
  text: string;
}

export interface LetterQuoteParagraphBlock {
  type: 'paragraph';
  /** Supports inline **bold** markers (wrap-safe). */
  text: string;
}

export interface LetterQuoteBulletsBlock {
  type: 'bullets';
  /** Each item supports inline **bold** markers. */
  items: string[];
}

export type LetterQuoteDescriptionBlock =
  | LetterQuoteHeadingBlock
  | LetterQuoteParagraphBlock
  | LetterQuoteBulletsBlock;

export interface LetterQuoteDescriptionPage {
  type: 'description';
  blocks: LetterQuoteDescriptionBlock[];
}

export interface LetterQuoteItemizedSection {
  heading: string;
  /**
   * Line items. Each supports inline **bold** markers — typically used for
   * parenthetical inclusions like "**(MATERIAL INCLUIDO)**".
   */
  items: string[];
}

export interface LetterQuoteItemizedPage {
  type: 'itemized';
  /** Centred tracked banner under the hero rule. */
  subtitle?: string;
  /** Left half of the project row. Renderer appends a colon. */
  project_label?: string;
  /** Right half of the project row (bold, tracked). */
  project_description?: string;
  sections: LetterQuoteItemizedSection[];
  currency?: string;
  subtotal?: number;
  /** Fraction — 0.21 means 21%. */
  tax_rate?: number;
  total?: number;
  /** Preferred for localised currency formatting (e.g. "€20.310"). */
  subtotal_text?: string;
  tax_text?: string;
  total_text?: string;
}

export type LetterQuotePage = LetterQuoteDescriptionPage | LetterQuoteItemizedPage;

export interface LetterQuoteData {
  company: LetterQuoteCompany;
  client: string;
  date: string;
  style?: LetterQuoteStyle;
  pages: LetterQuotePage[];
}

export interface ZigPdfLoader {
  isLoaded: boolean;
  isLoading: boolean;
  error: Error | null;
  module: ZigPdfModule | null;
  load: () => Promise<ZigPdfModule>;
}
