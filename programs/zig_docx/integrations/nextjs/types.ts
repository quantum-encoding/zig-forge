// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

/**
 * TypeScript types for the zig_docx web module (Fire Risk Assessment).
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
  getVersion: () => string;
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
