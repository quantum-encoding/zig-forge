// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

/**
 * TypeScript types for the zig_docx web module (Fire Risk Assessment,
 * redline sheets, Markdown ↔ DOCX).
 * Mirrors `FraData` in src/fra.zig — every field is optional; the Zig
 * generator supplies sensible defaults and PAS 79 boilerplate for anything
 * omitted. Serialise with JSON.stringify and pass to
 * ZigDocxModule.generateFireRiskAssessment.
 *
 * Methodology / compliance: PAS 79, Fire (Scotland) Act 2005 + Fire Safety
 * (Scotland) Regulations 2006, and the Regulatory Reform (Fire Safety)
 * Order 2005 (England & Wales). The `jurisdiction` field selects which
 * legislation the boilerplate cites.
 */

export interface ZigDocxModule {
  /** JSON (FraData) → Fire Risk Assessment .docx bytes. */
  generateFireRiskAssessment: (jsonString: string) => Uint8Array;
  /** Redline proofreading sheet → .docx bytes. Throws with the reason ("zig_docx: Redline JSON: InvalidColor"). */
  generateRedline: (sheet: RedlineSheet) => Uint8Array;
  /** The redline sheet of what changed from one .docx to another. */
  compareDocx: (before: Uint8Array, after: Uint8Array, options?: RedlineOptions) => Uint8Array;
  /** Markdown (with ~~strike~~, ==highlight==, [text]{color= bg=}, CriticMarkup) → .docx bytes. */
  markdownToDocx: (markdown: string) => Uint8Array;
  /** .docx → Markdown; struck runs come back as ~~text~~, highlighted as ==text==. */
  docxToMarkdown: (docx: Uint8Array) => string;
  getVersion: () => string;
}

/** Six hex digits ("A00000" or "#A00000"), #rgb, or a colour name ("red", "lightgreen"). */
export type RedlineColor = string;

/** One fix: `before` and `after` are plain text; the sheet word-diffs them. */
export interface RedlineItem {
  where?: string;
  before?: string;
  after?: string;
  /** Grey italic note under the new text (its own column in tracked mode). */
  note?: string | null;
}

export interface RedlineGroup {
  /** Shown in a dark row above the items; "" for no row. */
  name?: string;
  items?: RedlineItem[];
}

/** Everything about a sheet but its fixes; the options for compareDocx. */
export interface RedlineOptions {
  title?: string;
  /** Inline Markdown under the title; omit for the default key, "" for none. */
  key?: string | null;
  /** "redline" (colours, default) or "tracked" (Word tracked changes). */
  mode?: 'redline' | 'tracked';
  /** Tracked changes: who made them. Default "Reviewer". */
  author?: string;
  /** Tracked changes: "YYYY-MM-DD" or an ISO 8601 timestamp. Omitted = no date. */
  date?: string;
  orientation?: 'landscape' | 'portrait';
  labels?: { where?: string; before?: string; after?: string; change?: string; note?: string };
  colors?: {
    removed?: RedlineColor; removed_fill?: RedlineColor;
    added?: RedlineColor; added_fill?: RedlineColor;
    note?: RedlineColor; group_fill?: RedlineColor; group_text?: RedlineColor;
    header_fill?: RedlineColor; border?: RedlineColor;
  };
}

export interface RedlineSheet extends RedlineOptions {
  groups?: RedlineGroup[];
  /** One group with no name row. */
  items?: RedlineItem[];
}

/** One question/answer row within a checklist section. */
export interface FraChecklistItem {
  question?: string;
  /** Typically "Yes" | "No" | "N/A" | "TBC". */
  answer?: string;
  /** Cross-reference to an action plan item number, e.g. "1". Empty = none. */
  action_ref?: string;
}

/** A data-driven checklist section (PAS 79 hazard category). */
export interface FraChecklistSection {
  /** e.g. "Sources of Ignition". */
  category?: string;
  /** e.g. "Electrical Safety". */
  title?: string;
  items?: FraChecklistItem[];
  additional_info?: string;
  /**
   * Photo evidence for this section. Each entry is either:
   *  • a base64 image data URL — `"data:image/png;base64,…"` (png, jpeg, or
   *    gif). Decoded and embedded inline; this is the form the browser/web
   *    wasm uses, since it has no filesystem. Use this from the website.
   *  • a filename resolved against `image_dir` and read from disk — native
   *    CLI / FFI builds only; SKIPPED by the freestanding web wasm.
   */
  images?: string[];
}

/** One row of the action plan. */
export interface FraActionItem {
  number?: string;
  /** "High" | "Medium" | "Low" | "Advice". */
  priority?: string;
  recommendation?: string;
  comments?: string;
  date?: string;
  sign?: string;
}

export interface FraData {
  // ── Assessor company ──
  assessor_company?: string;
  assessor_address?: string;
  assessor_tel?: string;
  assessor_mobile?: string;
  assessor_web?: string;
  assessor_email?: string;
  assessor_name?: string;
  assessor_qualifications?: string;

  // ── Client / premises ──
  client_name?: string;
  client_address?: string;
  client_postcode?: string;

  // ── Assessment metadata ──
  assessment_date?: string;
  review_date?: string;
  info_provider?: string;
  competent_person?: string;

  /** "scotland" (default) or "england" — selects the cited legislation. */
  jurisdiction?: 'scotland' | 'england';

  // ── General info ──
  employer?: string;
  enforcing_authority?: string;
  alterations_notice?: string;

  // ── Premises details ──
  floors_description?: string;
  construction_details?: string;
  business_process?: string;

  // ── Fire alarm ──
  alarm_type?: string;
  alarm_panel_location?: string;
  alarm_covers_all?: string;
  alarm_authorized_person?: string;

  // ── Occupancy ──
  max_employees?: string;
  max_visitors?: string;
  sleeping_occupants?: string;
  impaired_occupants?: string;
  young_persons?: string;
  remote_workers?: string;
  other_occupants?: string;

  // ── Previous incidents ──
  previous_fires?: string;
  previous_false_alarms?: string;

  // ── Checklist sections (dynamic) ──
  sections?: FraChecklistSection[];

  // ── Risk rating ──
  risk_likelihood?: string;
  risk_consequence?: string;
  risk_overall?: string;

  // ── Action plan ──
  actions?: FraActionItem[];

  // ── Overrides ──
  custom_introduction?: string;
  custom_declaration?: string;

  /** Base path for resolving section image filenames. Native/CLI only. */
  image_dir?: string;
}
