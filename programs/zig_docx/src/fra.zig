// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Fire Risk Assessment (FRA) Document Generator
//!
//! Generates professional Fire Risk Assessment DOCX documents from JSON input.
//! Follows PAS 79 methodology and complies with:
//!   - Fire (Scotland) Act 2005, Sections 53 and 54
//!   - Fire Safety (Scotland) Regulations 2006
//!   - Regulatory Reform (Fire Safety) Order 2005 (England & Wales)
//!
//! The JSON schema is flexible — all sections are data-driven so any premises
//! type can be assessed. Standard boilerplate text is built-in but can be
//! overridden via the JSON.

const std = @import("std");
const docx = @import("docx.zig");
const docx_writer = @import("docx_writer.zig");

// ─── JSON Data Model ───────────────────────────────────────────────

pub const FraData = struct {
    // Assessor company
    assessor_company: []const u8 = "Fire Safe Assessment",
    assessor_address: []const u8 = "",
    assessor_tel: []const u8 = "",
    assessor_mobile: []const u8 = "",
    assessor_web: []const u8 = "",
    assessor_email: []const u8 = "",
    assessor_name: []const u8 = "",
    assessor_qualifications: []const u8 = "",

    // Client / premises
    client_name: []const u8 = "",
    client_address: []const u8 = "",
    client_postcode: []const u8 = "",

    // Assessment metadata
    assessment_date: []const u8 = "",
    review_date: []const u8 = "",
    info_provider: []const u8 = "",
    competent_person: []const u8 = "To be confirmed",

    // Legislation (scotland or england)
    jurisdiction: []const u8 = "scotland",

    // General info
    employer: []const u8 = "",
    enforcing_authority: []const u8 = "",
    alterations_notice: []const u8 = "No",

    // Premises details
    floors_description: []const u8 = "",
    construction_details: []const u8 = "",
    business_process: []const u8 = "",

    // Fire alarm
    alarm_type: []const u8 = "",
    alarm_panel_location: []const u8 = "",
    alarm_covers_all: []const u8 = "Yes",
    alarm_authorized_person: []const u8 = "",

    // Occupancy
    max_employees: []const u8 = "",
    max_visitors: []const u8 = "",
    sleeping_occupants: []const u8 = "None",
    impaired_occupants: []const u8 = "",
    young_persons: []const u8 = "0",
    remote_workers: []const u8 = "",
    other_occupants: []const u8 = "0",

    // Previous incidents
    previous_fires: []const u8 = "None",
    previous_false_alarms: []const u8 = "",

    // Checklist sections (dynamic)
    sections: []const ChecklistSection = &[_]ChecklistSection{},

    // Risk rating
    risk_likelihood: []const u8 = "MEDIUM",
    risk_consequence: []const u8 = "MODERATE",
    risk_overall: []const u8 = "MODERATE RISK",

    // Action plan
    actions: []const ActionItem = &[_]ActionItem{},

    // Custom introduction override (empty = use default)
    custom_introduction: []const u8 = "",
    custom_declaration: []const u8 = "",
};

pub const ChecklistSection = struct {
    category: []const u8 = "", // e.g. "Sources of Ignition"
    title: []const u8 = "", // e.g. "Electrical & Lightning"
    items: []const ChecklistItem = &[_]ChecklistItem{},
    additional_info: []const u8 = "",
};

pub const ChecklistItem = struct {
    question: []const u8 = "",
    answer: []const u8 = "", // "Yes", "No", "N/A", "TBC"
    action_ref: []const u8 = "", // e.g. "1", "2", empty
};

pub const ActionItem = struct {
    number: []const u8 = "",
    priority: []const u8 = "", // "High", "Medium", "Low", "Advice"
    recommendation: []const u8 = "",
    comments: []const u8 = "",
    date: []const u8 = "",
    sign: []const u8 = "",
};

// ─── Generator ─────────────────────────────────────────────────────

/// Generate a complete FRA DOCX from structured data.
pub fn generateFra(allocator: std.mem.Allocator, data: *const FraData) ![]u8 {
    var elements: std.ArrayListUnmanaged(docx.Element) = .empty;
    defer {
        for (elements.items) |*e| freeElement(allocator, e);
        elements.deinit(allocator);
    }

    // ── Cover page ──
    try addCoverPage(allocator, &elements, data);

    // ── Introduction ──
    try addHeading(allocator, &elements, "INTRODUCTION", .heading1);
    if (data.custom_introduction.len > 0) {
        try addParagraph(allocator, &elements, data.custom_introduction);
    } else {
        try addIntroductionBoilerplate(allocator, &elements);
    }

    // ── Declaration ──
    try addHeading(allocator, &elements, "DECLARATION", .heading1);
    if (data.custom_declaration.len > 0) {
        try addParagraph(allocator, &elements, data.custom_declaration);
    } else {
        try addDeclarationBoilerplate(allocator, &elements);
    }

    // ── Important Information ──
    try addHeading(allocator, &elements, "IMPORTANT INFORMATION", .heading1);
    try addImportantInfoBoilerplate(allocator, &elements, data);

    // ── Review ──
    try addHeading(allocator, &elements, "REVIEW OF THE FIRE RISK ASSESSMENT", .heading1);
    try addReviewBoilerplate(allocator, &elements);

    // ── Methodology ──
    try addHeading(allocator, &elements, "METHODOLOGY", .heading1);
    try addMethodologyBoilerplate(allocator, &elements);

    // ── Signatures ──
    try addHeading(allocator, &elements, "SIGNATURES", .heading1);
    try addSignaturesTable(allocator, &elements, data);

    // ── General Information ──
    try addHeading(allocator, &elements, "General Information", .heading1);
    try addGeneralInfoTable(allocator, &elements, data);

    // ── Premises ──
    try addHeading(allocator, &elements, "Premises", .heading1);
    try addPremisesTable(allocator, &elements, data);

    // ── Fire Alarm System ──
    try addHeading(allocator, &elements, "Fire Alarm System", .heading1);
    try addFireAlarmTable(allocator, &elements, data);

    // ── Occupancy Profile ──
    try addHeading(allocator, &elements, "Occupancy Profile", .heading1);
    try addOccupancyTable(allocator, &elements, data);

    // ── Previous Fires ──
    try addHeading(allocator, &elements, "Previous Fires and False Alarms", .heading1);
    try addPreviousIncidentsTable(allocator, &elements, data);

    // ── Checklist Sections (dynamic) ──
    var last_category: []const u8 = "";
    for (data.sections) |section| {
        // Print category heading if changed
        if (!std.mem.eql(u8, section.category, last_category)) {
            try addHeading(allocator, &elements, section.category, .heading1);
            last_category = section.category;
        }
        try addChecklistSection(allocator, &elements, &section);
    }

    // ── Scoring Matrix ──
    try addHeading(allocator, &elements, "SCORING MATRIX", .heading1);
    try addScoringMatrix(allocator, &elements);

    // ── Risk Rating ──
    try addHeading(allocator, &elements, "RISK RATING", .heading1);
    try addRiskRating(allocator, &elements, data);

    // ── Action Plan ──
    try addHeading(allocator, &elements, "Action Plan", .heading1);
    try addActionPlanLegend(allocator, &elements);
    if (data.actions.len > 0) {
        try addActionPlanTable(allocator, &elements, data);
    }

    // Build document
    const doc = docx.Document{
        .elements = try elements.toOwnedSlice(allocator),
        .media = &[_]docx.MediaFile{},
        .allocator = allocator,
    };
    // Don't deinit doc — elements ownership transferred, docx_writer reads them

    const opts = docx_writer.DocxWriterOptions{
        .title = "Fire Risk Assessment",
        .author = data.assessor_name,
        .date = data.assessment_date,
    };

    return docx_writer.generateDocx(allocator, &doc, opts);
}

// ─── Cover Page ────────────────────────────────────────────────────

fn addCoverPage(allocator: std.mem.Allocator, elements: *std.ArrayListUnmanaged(docx.Element), data: *const FraData) !void {
    // Assessor company details
    if (data.assessor_address.len > 0)
        try addParagraph(allocator, elements, data.assessor_address);
    if (data.assessor_tel.len > 0) {
        const tel = try std.fmt.allocPrint(allocator, "Tel. {s}", .{data.assessor_tel});
        defer allocator.free(tel);
        try addParagraph(allocator, elements, tel);
    }
    if (data.assessor_mobile.len > 0) {
        const mob = try std.fmt.allocPrint(allocator, "Mobile {s}", .{data.assessor_mobile});
        defer allocator.free(mob);
        try addParagraph(allocator, elements, mob);
    }
    if (data.assessor_web.len > 0) {
        const web_text = try std.fmt.allocPrint(allocator, "Web {s}", .{data.assessor_web});
        defer allocator.free(web_text);
        try addParagraph(allocator, elements, web_text);
    }
    if (data.assessor_email.len > 0) {
        const email_text = try std.fmt.allocPrint(allocator, "Email {s}", .{data.assessor_email});
        defer allocator.free(email_text);
        try addParagraph(allocator, elements, email_text);
    }

    // Title
    try addHeading(allocator, elements, "FIRE RISK ASSESSMENT", .heading1);

    // Client details
    try addParagraph(allocator, elements, data.client_name);
    try addParagraph(allocator, elements, data.client_address);
    if (data.client_postcode.len > 0)
        try addParagraph(allocator, elements, data.client_postcode);

    // Legislation reference
    const leg = if (std.mem.eql(u8, data.jurisdiction, "england"))
        "Regulatory Reform (Fire Safety) Order 2005"
    else
        "Fire (Scotland) Act 2005\nFire Safety (Scotland) Regulations 2006";
    try addParagraph(allocator, elements, leg);
}

// ─── Boilerplate Sections ──────────────────────────────────────────

fn addIntroductionBoilerplate(allocator: std.mem.Allocator, elements: *std.ArrayListUnmanaged(docx.Element)) !void {
    try addParagraph(allocator, elements,
        "The purpose of this report is to present the findings of the assessment in relation to the risk to life and property from a fire breaking out within the premises and to make recommendations to the duty holder of the premises in order to comply with Fire legislation.",
    );
    try addParagraph(allocator, elements,
        "The report does not address the risk of business continuity from fire; however, issues raised may if not addressed have the following implications:",
    );

    const implications = [_][]const u8{
        "Significant financial implications.",
        "Significant impact on business continuity.",
        "Statutory non-compliances.",
        "Potential for significant exposure (public liability/employers' liability) regarding litigation.",
        "Potential for losses and injuries.",
    };
    for (implications) |item| {
        try addListItem(allocator, elements, item, false);
    }

    try addItalicParagraph(allocator, elements,
        "Please note that this report and any recommendations made within are based on the use and conditions observed and the information supplied to the assessor at the time. It is not intended to be exhaustive or conclusive, covering every hazard or potential risk, or to guarantee compliance with any statute regulation. It is offered to assist you in your continued management of potential risks",
    );
}

fn addDeclarationBoilerplate(allocator: std.mem.Allocator, elements: *std.ArrayListUnmanaged(docx.Element)) !void {
    try addParagraph(allocator, elements,
        "The contents of this document are based upon information that was obtained by visual examination of the premises, examination of available documentation, verbal information provided and non-formal discussion/questioning of staff. It should be noted that the visual examination of the premises was of a non-destructive nature. In addition, the fire alarm, fire detection system, air conditioning, fire dampers and emergency lighting received a visual inspection only.",
    );
    try addParagraph(allocator, elements,
        "Comments relating to security measures relating to arson/willful fire raising are only in the context of this fire risk assessment, e.g. CCTV coverage. If further advice on security is required then a security specialist should be consulted.",
    );
    try addParagraph(allocator, elements,
        "No guarantee can be given that during any subsequent visit by Enforcing Authority Officers with statutory powers that non-compliances may be found resulting in enforcement procedures being instigated. Responsibility for any loss arising from such a discovery will not be accepted by the Fire Risk Assessor or associated companies.",
    );
    try addParagraph(allocator, elements,
        "Failure to maintain the levels of fire protection provided, or the standards of routine fire precautions and safe working practices, may invalidate the Fire Risk Assessment.",
    );
    try addParagraph(allocator, elements,
        "Whilst every care is taken to interpret the Acts, Regulations, Guidance and Approved Codes of Practices, these can only be authoritatively interpreted by Court of Law.",
    );
}

fn addImportantInfoBoilerplate(allocator: std.mem.Allocator, elements: *std.ArrayListUnmanaged(docx.Element), data: *const FraData) !void {
    try addParagraph(allocator, elements,
        "This fire risk assessment has been conducted to assist in the compliance with current Fire Legislation:",
    );

    if (std.mem.eql(u8, data.jurisdiction, "england")) {
        try addParagraph(allocator, elements, "England & Wales:");
        try addListItem(allocator, elements, "Regulatory Reform (Fire Safety) Order 2005", false);
    } else {
        try addParagraph(allocator, elements, "Scotland:");
        try addListItem(allocator, elements, "Fire (Scotland) Act 2005, Sections 53 and 54", false);
        try addListItem(allocator, elements, "Fire Safety (Scotland) Regulations 2006", false);
    }

    try addParagraph(allocator, elements,
        "It is important that the contents of the fire risk assessment are understood by the person with duties under the relevant fire legislation, i.e. the duty holder. The fire risk assessment includes an Action Plan, which sets out the measures considered necessary to satisfy the requirements of the above legislation and to protect relevant persons from fire. (Relevant persons are primarily anyone who is, or may be, lawfully within the premises; who is, or may be, in the immediate vicinity of the premises; and whose safety would be at risk in the event of fire in the premises).",
    );

    try addParagraph(allocator, elements, "You must record the above arrangements if:");
    const conditions = [_][]const u8{
        "You employ five or more employees in your undertaking (regardless of where they are employed);",
        "Licensing, certification or registration under other legislation is in force; or",
        "An alterations notice is in force requiring a record to be kept.",
    };
    for (conditions) |c| {
        try addListItem(allocator, elements, c, false);
    }
}

fn addReviewBoilerplate(allocator: std.mem.Allocator, elements: *std.ArrayListUnmanaged(docx.Element)) !void {
    try addParagraph(allocator, elements, "The assessment must be reviewed periodically or if the following conditions occur:");
    const triggers = [_][]const u8{
        "there is reason to suspect that it is no longer valid; or",
        "there has been a significant change in the matters to which it relates including when the relevant premises, special, technical and organisational measures or organisation of the work undergo significant changes.",
        "A fire incident has occurred.",
    };
    for (triggers) |t| {
        try addListItem(allocator, elements, t, false);
    }
}

fn addMethodologyBoilerplate(allocator: std.mem.Allocator, elements: *std.ArrayListUnmanaged(docx.Element)) !void {
    try addParagraph(allocator, elements,
        "The method used to undertake the risk assessment follows Publicly Available Specifications and is based on the framework as described within PAS 79:",
    );
    const steps = [_][]const u8{
        "Assessment of the building, processes within the building and the person present or likely to be present within the building",
        "Identification of fire hazards and means of elimination or control of these hazards",
        "An assessment of likelihood of a fire",
        "Determine the fire prevention methods in place",
        "Obtain information on Fire Safety management",
        "Assess the potential consequences to people in the event of fire",
        "Assess the overall fire risk",
        "Formulate an action plan",
        "Define a review date",
    };
    for (steps) |s| {
        try addListItem(allocator, elements, s, false);
    }
}

// ─── Data Tables ───────────────────────────────────────────────────

fn addSignaturesTable(allocator: std.mem.Allocator, elements: *std.ArrayListUnmanaged(docx.Element), data: *const FraData) !void {
    const name_str = if (data.assessor_qualifications.len > 0)
        try std.fmt.allocPrint(allocator, "{s}, {s}", .{ data.assessor_name, data.assessor_qualifications })
    else
        try allocator.dupe(u8, data.assessor_name);
    defer allocator.free(name_str);

    const rows_data = [_][2][]const u8{
        .{ "Assessors Name (Print)", name_str },
        .{ "Assessors Signature", "" },
        .{ "Date of Assessment", data.assessment_date },
        .{ "Review Date", data.review_date },
        .{ "", "" },
        .{ "Person(s) providing information during assessment", data.info_provider },
        .{ "Competent person appointed under Regulation 17 of the Fire Scotland Regulations 2006 by the duty holder to implement fire safety measures", data.competent_person },
        .{ "Signature of competent person", "" },
        .{ "Date", "" },
    };
    try addKeyValueTable(allocator, elements, &rows_data);
}

fn addGeneralInfoTable(allocator: std.mem.Allocator, elements: *std.ArrayListUnmanaged(docx.Element), data: *const FraData) !void {
    const addr = if (data.client_postcode.len > 0)
        try std.fmt.allocPrint(allocator, "{s} {s}", .{ data.client_address, data.client_postcode })
    else
        try allocator.dupe(u8, data.client_address);
    defer allocator.free(addr);

    const rows_data = [_][2][]const u8{
        .{ "Person having control of the premises (Employer)", data.employer },
        .{ "Address of Premises", addr },
        .{ "Enforcing Authority", data.enforcing_authority },
        .{ "Is there an alterations notice in force?", data.alterations_notice },
    };
    try addKeyValueTable(allocator, elements, &rows_data);
}

fn addPremisesTable(allocator: std.mem.Allocator, elements: *std.ArrayListUnmanaged(docx.Element), data: *const FraData) !void {
    const rows_data = [_][2][]const u8{
        .{ "No. of floors", data.floors_description },
        .{ "Brief details of construction", data.construction_details },
        .{ "Business process", data.business_process },
    };
    try addKeyValueTable(allocator, elements, &rows_data);
}

fn addFireAlarmTable(allocator: std.mem.Allocator, elements: *std.ArrayListUnmanaged(docx.Element), data: *const FraData) !void {
    const rows_data = [_][2][]const u8{
        .{ "Type of system", data.alarm_type },
        .{ "Location of Indicator Panel", data.alarm_panel_location },
        .{ "Does alarm system cover all relevant parts of the premises", data.alarm_covers_all },
        .{ "Person with authorisation to test, silence and reset alarm", data.alarm_authorized_person },
    };
    try addKeyValueTable(allocator, elements, &rows_data);
}

fn addOccupancyTable(allocator: std.mem.Allocator, elements: *std.ArrayListUnmanaged(docx.Element), data: *const FraData) !void {
    const rows_data = [_][2][]const u8{
        .{ "Employees", data.max_employees },
        .{ "Visitors", data.max_visitors },
        .{ "Sleeping Occupants", data.sleeping_occupants },
        .{ "Occupants with physical, visual, hearing impairment", data.impaired_occupants },
        .{ "Young Persons", data.young_persons },
        .{ "Persons in remote areas", data.remote_workers },
        .{ "Others", data.other_occupants },
    };
    try addKeyValueTable(allocator, elements, &rows_data);
}

fn addPreviousIncidentsTable(allocator: std.mem.Allocator, elements: *std.ArrayListUnmanaged(docx.Element), data: *const FraData) !void {
    const combined = try std.fmt.allocPrint(allocator, "{s} / {s}", .{ data.previous_fires, data.previous_false_alarms });
    defer allocator.free(combined);
    const rows_data = [_][2][]const u8{
        .{ "Fires / False Alarms", combined },
    };
    try addKeyValueTable(allocator, elements, &rows_data);
}

// ─── Checklist Sections ────────────────────────────────────────────

// Column widths matching the original document (in dxa = twentieths of a point)
// Total page content width: 8296 dxa (A4 with standard margins)
const COL_2_LABEL: u16 = 3400; // 2-column: label width
const COL_2_VALUE: u16 = 4896; // 2-column: value width
const COL_3_QUESTION: u16 = 5691; // 3-column checklist: question
const COL_3_ANSWER: u16 = 1233; // 3-column checklist: Yes/No
const COL_3_ACTION: u16 = 1372; // 3-column checklist: Action Plan
const COL_1_FULL: u16 = 8296; // Full-width single column

fn addChecklistSection(allocator: std.mem.Allocator, elements: *std.ArrayListUnmanaged(docx.Element), section: *const ChecklistSection) !void {
    // Section title as heading
    try addHeading(allocator, elements, section.title, .heading2);

    if (section.items.len > 0) {
        // Build checklist table: header + items
        var rows: std.ArrayListUnmanaged(docx.TableRow) = .empty;
        defer rows.deinit(allocator);

        // Header row
        const hdr_cells = try allocator.alloc(docx.TableCell, 3);
        hdr_cells[0] = try makeBoldCell(allocator, section.title);
        hdr_cells[1] = try makeBoldCell(allocator, "Yes / No");
        hdr_cells[2] = try makeBoldCell(allocator, "Action Plan No.");
        try rows.append(allocator, .{ .cells = hdr_cells });

        // Data rows
        for (section.items) |item| {
            const item_cells = try allocator.alloc(docx.TableCell, 3);
            item_cells[0] = try makeCell(allocator, item.question);
            item_cells[1] = try makeCell(allocator, item.answer);
            item_cells[2] = try makeCell(allocator, item.action_ref);
            try rows.append(allocator, .{ .cells = item_cells });
        }

        const col3_widths = try allocator.dupe(u16, &[_]u16{ COL_3_QUESTION, COL_3_ANSWER, COL_3_ACTION });
        try elements.append(allocator, .{ .table = .{
            .rows = try rows.toOwnedSlice(allocator),
            .col_widths = col3_widths,
        } });
    }

    // Additional information box
    if (section.additional_info.len > 0) {
        var info_rows: std.ArrayListUnmanaged(docx.TableRow) = .empty;
        defer info_rows.deinit(allocator);

        const hdr = try allocator.alloc(docx.TableCell, 1);
        hdr[0] = try makeBoldCell(allocator, "Additional Information");
        try info_rows.append(allocator, .{ .cells = hdr });

        const body_cell = try allocator.alloc(docx.TableCell, 1);
        body_cell[0] = try makeCell(allocator, section.additional_info);
        try info_rows.append(allocator, .{ .cells = body_cell });

        const col1_widths = try allocator.dupe(u16, &[_]u16{COL_1_FULL});
        try elements.append(allocator, .{ .table = .{
            .rows = try info_rows.toOwnedSlice(allocator),
            .col_widths = col1_widths,
        } });
    }
}

// ─── Scoring Matrix ────────────────────────────────────────────────

fn addScoringMatrix(allocator: std.mem.Allocator, elements: *std.ArrayListUnmanaged(docx.Element)) !void {
    var rows: std.ArrayListUnmanaged(docx.TableRow) = .empty;
    defer rows.deinit(allocator);

    // Header row
    const hdr = try allocator.alloc(docx.TableCell, 4);
    hdr[0] = try makeBoldCell(allocator, "Consequences of fire →\nFire Hazard likelihood ↓");
    hdr[1] = try makeBoldCell(allocator, "Slight Harm");
    hdr[2] = try makeBoldCell(allocator, "Moderate Harm");
    hdr[3] = try makeBoldCell(allocator, "Serious Harm");
    try rows.append(allocator, .{ .cells = hdr });

    const matrix = [_][4][]const u8{
        .{ "LOW", "Trivial Risk", "Tolerable Risk", "Moderate Risk" },
        .{ "MEDIUM", "Tolerable Risk", "Moderate Risk", "Substantial Risk" },
        .{ "HIGH", "Moderate Risk", "Substantial Risk", "Intolerable Risk" },
    };

    for (matrix) |row_data| {
        const cells = try allocator.alloc(docx.TableCell, 4);
        cells[0] = try makeBoldCell(allocator, row_data[0]);
        cells[1] = try makeCell(allocator, row_data[1]);
        cells[2] = try makeCell(allocator, row_data[2]);
        cells[3] = try makeCell(allocator, row_data[3]);
        try rows.append(allocator, .{ .cells = cells });
    }

    const col4_widths = try allocator.dupe(u16, &[_]u16{ 2600, 1900, 1900, 1896 });
    try elements.append(allocator, .{ .table = .{
        .rows = try rows.toOwnedSlice(allocator),
        .col_widths = col4_widths,
    } });

    // Definitions
    try addParagraph(allocator, elements, "In this context, a definition of the above terms regarding likelihood and consequences of a fire is as follows:");

    try addBoldParagraph(allocator, elements, "Fire Hazard likelihood");
    try addListItem(allocator, elements, "Low: Outbreak of fire unlikely with negligible potential ignition sources", false);
    try addListItem(allocator, elements, "Medium: Outbreak of fire possible but not likely, with fire hazards controlled", false);
    try addListItem(allocator, elements, "High: Outbreak of fire likely with significant fire hazards and inadequate controls", false);

    try addBoldParagraph(allocator, elements, "Consequences of fire");
    try addListItem(allocator, elements, "Slight harm: Fire unlikely to result in serious injury or death of any occupant.", false);
    try addListItem(allocator, elements, "Moderate harm: Injury of one or more occupants, but it is unlikely to involve serious injury or fatalities.", false);
    try addListItem(allocator, elements, "Serious harm: Potential for serious injury or death of one or more occupants.", false);
}

// ─── Risk Rating ───────────────────────────────────────────────────

fn addRiskRating(allocator: std.mem.Allocator, elements: *std.ArrayListUnmanaged(docx.Element), data: *const FraData) !void {
    try addParagraph(allocator, elements,
        "Taking into account the fire prevention measures observed at the time of this risk assessment, it is considered, that the hazard from fire (likelihood of ignition) within the building is:",
    );
    try addBoldParagraph(allocator, elements, data.risk_likelihood);

    try addParagraph(allocator, elements,
        "Taking into account the nature of the building and the occupants, as well as the fire protection and procedural arrangements observed at the time of this risk assessment, it is considered that the consequences of a fire to persons would be:",
    );
    try addBoldParagraph(allocator, elements, data.risk_consequence);

    try addBoldParagraph(allocator, elements, "The risk to life from fire within this building is:");
    try addBoldParagraph(allocator, elements, data.risk_overall);

    try addParagraph(allocator, elements,
        "A suitable risk-based control plan should involve effort and urgency that is proportional to risk.",
    );
    try addParagraph(allocator, elements,
        "It is considered that the recommendations contained with the Action Plan should be implemented in order to reduce the likelihood of fire and subsequent consequences to reduce the Risk Level to Tolerable or trivial.",
    );

    // Risk level table
    var rows: std.ArrayListUnmanaged(docx.TableRow) = .empty;
    defer rows.deinit(allocator);

    const levels = [_][2][]const u8{
        .{ "Trivial", "No action is required and no detailed records need be kept." },
        .{ "Tolerable", "No major additional controls required. However, there may be a need for consideration of improvements that involve minor or limited cost." },
        .{ "Moderate", "It is essential that efforts be made to reduce the risk. Risk reduction measures should be implemented within a defined time period." },
        .{ "Substantial", "Considerable resources may have to be allocated to reduce the risk. If the building is unoccupied, it should not be occupied until the risk has been reduced. If the building is occupied, urgent action should be taken." },
        .{ "Intolerable", "Building (or relevant area) should not be occupied until the risk is reduced." },
    };

    for (levels) |level| {
        const cells = try allocator.alloc(docx.TableCell, 2);
        cells[0] = try makeBoldCell(allocator, level[0]);
        cells[1] = try makeCell(allocator, level[1]);
        try rows.append(allocator, .{ .cells = cells });
    }

    const risk_col_widths = try allocator.dupe(u16, &[_]u16{ 1800, 6496 });
    try elements.append(allocator, .{ .table = .{
        .rows = try rows.toOwnedSlice(allocator),
        .col_widths = risk_col_widths,
    } });
}

// ─── Action Plan ───────────────────────────────────────────────────

fn addActionPlanLegend(allocator: std.mem.Allocator, elements: *std.ArrayListUnmanaged(docx.Element)) !void {
    var rows: std.ArrayListUnmanaged(docx.TableRow) = .empty;
    defer rows.deinit(allocator);

    const legend = [_][2][]const u8{
        .{ "High", "Requires urgent action (immediately resolved or action initiated)" },
        .{ "Medium", "Requires action (within 4-8 weeks)" },
        .{ "Low", "Requires attention (within 6 months)" },
        .{ "Advice", "Requires consideration" },
    };

    for (legend) |l| {
        const cells = try allocator.alloc(docx.TableCell, 2);
        cells[0] = try makeBoldCell(allocator, l[0]);
        cells[1] = try makeCell(allocator, l[1]);
        try rows.append(allocator, .{ .cells = cells });
    }

    const legend_widths = try allocator.dupe(u16, &[_]u16{ 1400, 6896 });
    try elements.append(allocator, .{ .table = .{
        .rows = try rows.toOwnedSlice(allocator),
        .col_widths = legend_widths,
    } });
}

fn addActionPlanTable(allocator: std.mem.Allocator, elements: *std.ArrayListUnmanaged(docx.Element), data: *const FraData) !void {
    var rows: std.ArrayListUnmanaged(docx.TableRow) = .empty;
    defer rows.deinit(allocator);

    // Header row
    const hdr = try allocator.alloc(docx.TableCell, 6);
    hdr[0] = try makeBoldCell(allocator, "No.");
    hdr[1] = try makeBoldCell(allocator, "Priority");
    hdr[2] = try makeBoldCell(allocator, "Recommendation");
    hdr[3] = try makeBoldCell(allocator, "Comments/Action");
    hdr[4] = try makeBoldCell(allocator, "Date");
    hdr[5] = try makeBoldCell(allocator, "Sign");
    try rows.append(allocator, .{ .cells = hdr });

    for (data.actions) |action| {
        const cells = try allocator.alloc(docx.TableCell, 6);
        cells[0] = try makeCell(allocator, action.number);
        cells[1] = try makeCell(allocator, action.priority);
        cells[2] = try makeCell(allocator, action.recommendation);
        cells[3] = try makeCell(allocator, action.comments);
        cells[4] = try makeCell(allocator, action.date);
        cells[5] = try makeCell(allocator, action.sign);
        try rows.append(allocator, .{ .cells = cells });
    }

    const action_widths = try allocator.dupe(u16, &[_]u16{ 600, 900, 3800, 1500, 700, 796 });
    try elements.append(allocator, .{ .table = .{
        .rows = try rows.toOwnedSlice(allocator),
        .col_widths = action_widths,
    } });
}

// ─── Element Helpers ───────────────────────────────────────────────

fn addHeading(allocator: std.mem.Allocator, elements: *std.ArrayListUnmanaged(docx.Element), text: []const u8, style: docx.StyleType) !void {
    const runs = try allocator.alloc(docx.Run, 1);
    runs[0] = .{ .text = try allocator.dupe(u8, text), .bold = true };
    try elements.append(allocator, .{ .paragraph = .{ .style = style, .runs = runs } });
}

fn addParagraph(allocator: std.mem.Allocator, elements: *std.ArrayListUnmanaged(docx.Element), text: []const u8) !void {
    const runs = try allocator.alloc(docx.Run, 1);
    runs[0] = .{ .text = try allocator.dupe(u8, text) };
    try elements.append(allocator, .{ .paragraph = .{ .style = .normal, .runs = runs } });
}

fn addBoldParagraph(allocator: std.mem.Allocator, elements: *std.ArrayListUnmanaged(docx.Element), text: []const u8) !void {
    const runs = try allocator.alloc(docx.Run, 1);
    runs[0] = .{ .text = try allocator.dupe(u8, text), .bold = true };
    try elements.append(allocator, .{ .paragraph = .{ .style = .normal, .runs = runs } });
}

fn addItalicParagraph(allocator: std.mem.Allocator, elements: *std.ArrayListUnmanaged(docx.Element), text: []const u8) !void {
    const runs = try allocator.alloc(docx.Run, 1);
    runs[0] = .{ .text = try allocator.dupe(u8, text), .italic = true };
    try elements.append(allocator, .{ .paragraph = .{ .style = .normal, .runs = runs } });
}

fn addListItem(allocator: std.mem.Allocator, elements: *std.ArrayListUnmanaged(docx.Element), text: []const u8, ordered: bool) !void {
    const runs = try allocator.alloc(docx.Run, 1);
    runs[0] = .{ .text = try allocator.dupe(u8, text) };
    try elements.append(allocator, .{ .paragraph = .{
        .style = .list_paragraph,
        .runs = runs,
        .is_list_item = true,
        .is_ordered = ordered,
    } });
}

fn makeCell(allocator: std.mem.Allocator, text: []const u8) !docx.TableCell {
    const runs = try allocator.alloc(docx.Run, 1);
    runs[0] = .{ .text = try allocator.dupe(u8, text) };
    const paras = try allocator.alloc(docx.Paragraph, 1);
    paras[0] = .{ .style = .normal, .runs = runs };
    return .{ .paragraphs = paras };
}

fn makeBoldCell(allocator: std.mem.Allocator, text: []const u8) !docx.TableCell {
    const runs = try allocator.alloc(docx.Run, 1);
    runs[0] = .{ .text = try allocator.dupe(u8, text), .bold = true };
    const paras = try allocator.alloc(docx.Paragraph, 1);
    paras[0] = .{ .style = .normal, .runs = runs };
    return .{ .paragraphs = paras };
}

fn addKeyValueTable(allocator: std.mem.Allocator, elements: *std.ArrayListUnmanaged(docx.Element), rows_data: []const [2][]const u8) !void {
    var rows: std.ArrayListUnmanaged(docx.TableRow) = .empty;
    defer rows.deinit(allocator);

    for (rows_data) |row_data| {
        const cells = try allocator.alloc(docx.TableCell, 2);
        cells[0] = try makeBoldCell(allocator, row_data[0]);
        cells[1] = try makeCell(allocator, row_data[1]);
        try rows.append(allocator, .{ .cells = cells });
    }

    const col2_widths = try allocator.dupe(u16, &[_]u16{ COL_2_LABEL, COL_2_VALUE });
    try elements.append(allocator, .{ .table = .{
        .rows = try rows.toOwnedSlice(allocator),
        .col_widths = col2_widths,
    } });
}

// ─── Memory Cleanup ────────────────────────────────────────────────

fn freeElement(allocator: std.mem.Allocator, elem: *docx.Element) void {
    switch (elem.*) {
        .paragraph => |p| {
            for (p.runs) |r| {
                if (r.text.len > 0) allocator.free(r.text);
                if (r.hyperlink_url) |u| allocator.free(u);
                if (r.image_rel_id) |rel| allocator.free(rel);
            }
            if (p.runs.len > 0) allocator.free(p.runs);
        },
        .table => |t| {
            for (t.rows) |row| {
                for (row.cells) |cell| {
                    for (cell.paragraphs) |cp| {
                        for (cp.runs) |r| {
                            if (r.text.len > 0) allocator.free(r.text);
                        }
                        if (cp.runs.len > 0) allocator.free(cp.runs);
                    }
                    allocator.free(cell.paragraphs);
                }
                allocator.free(row.cells);
            }
            allocator.free(t.rows);
        },
    }
}

// ─── JSON Parser ───────────────────────────────────────────────────

/// Parse FRA JSON into FraData. Caller must call freeFraData when done.
pub fn parseFraJson(allocator: std.mem.Allocator, json_str: []const u8) !FraData {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return error.InvalidJson;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidJson;
    const obj = root.object;

    var data = FraData{};

    // Simple string fields
    if (getStr(obj, "assessor_company")) |v| data.assessor_company = try allocator.dupe(u8, v);
    if (getStr(obj, "assessor_address")) |v| data.assessor_address = try allocator.dupe(u8, v);
    if (getStr(obj, "assessor_tel")) |v| data.assessor_tel = try allocator.dupe(u8, v);
    if (getStr(obj, "assessor_mobile")) |v| data.assessor_mobile = try allocator.dupe(u8, v);
    if (getStr(obj, "assessor_web")) |v| data.assessor_web = try allocator.dupe(u8, v);
    if (getStr(obj, "assessor_email")) |v| data.assessor_email = try allocator.dupe(u8, v);
    if (getStr(obj, "assessor_name")) |v| data.assessor_name = try allocator.dupe(u8, v);
    if (getStr(obj, "assessor_qualifications")) |v| data.assessor_qualifications = try allocator.dupe(u8, v);
    if (getStr(obj, "client_name")) |v| data.client_name = try allocator.dupe(u8, v);
    if (getStr(obj, "client_address")) |v| data.client_address = try allocator.dupe(u8, v);
    if (getStr(obj, "client_postcode")) |v| data.client_postcode = try allocator.dupe(u8, v);
    if (getStr(obj, "assessment_date")) |v| data.assessment_date = try allocator.dupe(u8, v);
    if (getStr(obj, "review_date")) |v| data.review_date = try allocator.dupe(u8, v);
    if (getStr(obj, "info_provider")) |v| data.info_provider = try allocator.dupe(u8, v);
    if (getStr(obj, "competent_person")) |v| data.competent_person = try allocator.dupe(u8, v);
    if (getStr(obj, "jurisdiction")) |v| data.jurisdiction = try allocator.dupe(u8, v);
    if (getStr(obj, "employer")) |v| data.employer = try allocator.dupe(u8, v);
    if (getStr(obj, "enforcing_authority")) |v| data.enforcing_authority = try allocator.dupe(u8, v);
    if (getStr(obj, "alterations_notice")) |v| data.alterations_notice = try allocator.dupe(u8, v);
    if (getStr(obj, "floors_description")) |v| data.floors_description = try allocator.dupe(u8, v);
    if (getStr(obj, "construction_details")) |v| data.construction_details = try allocator.dupe(u8, v);
    if (getStr(obj, "business_process")) |v| data.business_process = try allocator.dupe(u8, v);
    if (getStr(obj, "alarm_type")) |v| data.alarm_type = try allocator.dupe(u8, v);
    if (getStr(obj, "alarm_panel_location")) |v| data.alarm_panel_location = try allocator.dupe(u8, v);
    if (getStr(obj, "alarm_covers_all")) |v| data.alarm_covers_all = try allocator.dupe(u8, v);
    if (getStr(obj, "alarm_authorized_person")) |v| data.alarm_authorized_person = try allocator.dupe(u8, v);
    if (getStr(obj, "max_employees")) |v| data.max_employees = try allocator.dupe(u8, v);
    if (getStr(obj, "max_visitors")) |v| data.max_visitors = try allocator.dupe(u8, v);
    if (getStr(obj, "sleeping_occupants")) |v| data.sleeping_occupants = try allocator.dupe(u8, v);
    if (getStr(obj, "impaired_occupants")) |v| data.impaired_occupants = try allocator.dupe(u8, v);
    if (getStr(obj, "young_persons")) |v| data.young_persons = try allocator.dupe(u8, v);
    if (getStr(obj, "remote_workers")) |v| data.remote_workers = try allocator.dupe(u8, v);
    if (getStr(obj, "other_occupants")) |v| data.other_occupants = try allocator.dupe(u8, v);
    if (getStr(obj, "previous_fires")) |v| data.previous_fires = try allocator.dupe(u8, v);
    if (getStr(obj, "previous_false_alarms")) |v| data.previous_false_alarms = try allocator.dupe(u8, v);
    if (getStr(obj, "risk_likelihood")) |v| data.risk_likelihood = try allocator.dupe(u8, v);
    if (getStr(obj, "risk_consequence")) |v| data.risk_consequence = try allocator.dupe(u8, v);
    if (getStr(obj, "risk_overall")) |v| data.risk_overall = try allocator.dupe(u8, v);
    if (getStr(obj, "custom_introduction")) |v| data.custom_introduction = try allocator.dupe(u8, v);
    if (getStr(obj, "custom_declaration")) |v| data.custom_declaration = try allocator.dupe(u8, v);

    // Sections array
    if (obj.get("sections")) |sections_val| {
        if (sections_val == .array) {
            var sections: std.ArrayListUnmanaged(ChecklistSection) = .empty;
            for (sections_val.array.items) |section_val| {
                if (section_val != .object) continue;
                const sobj = section_val.object;

                var section = ChecklistSection{};
                if (getStr(sobj, "category")) |v| section.category = try allocator.dupe(u8, v);
                if (getStr(sobj, "title")) |v| section.title = try allocator.dupe(u8, v);
                if (getStr(sobj, "additional_info")) |v| section.additional_info = try allocator.dupe(u8, v);

                // Items
                if (sobj.get("items")) |items_val| {
                    if (items_val == .array) {
                        var items: std.ArrayListUnmanaged(ChecklistItem) = .empty;
                        for (items_val.array.items) |item_val| {
                            if (item_val != .object) continue;
                            const iobj = item_val.object;
                            var item = ChecklistItem{};
                            if (getStr(iobj, "question")) |v| item.question = try allocator.dupe(u8, v);
                            if (getStr(iobj, "answer")) |v| item.answer = try allocator.dupe(u8, v);
                            if (getStr(iobj, "action_ref")) |v| item.action_ref = try allocator.dupe(u8, v);
                            try items.append(allocator, item);
                        }
                        section.items = try items.toOwnedSlice(allocator);
                    }
                }
                try sections.append(allocator, section);
            }
            data.sections = try sections.toOwnedSlice(allocator);
        }
    }

    // Actions array
    if (obj.get("actions")) |actions_val| {
        if (actions_val == .array) {
            var actions: std.ArrayListUnmanaged(ActionItem) = .empty;
            for (actions_val.array.items) |action_val| {
                if (action_val != .object) continue;
                const aobj = action_val.object;
                var action = ActionItem{};
                if (getStr(aobj, "number")) |v| action.number = try allocator.dupe(u8, v);
                if (getStr(aobj, "priority")) |v| action.priority = try allocator.dupe(u8, v);
                if (getStr(aobj, "recommendation")) |v| action.recommendation = try allocator.dupe(u8, v);
                if (getStr(aobj, "comments")) |v| action.comments = try allocator.dupe(u8, v);
                if (getStr(aobj, "date")) |v| action.date = try allocator.dupe(u8, v);
                if (getStr(aobj, "sign")) |v| action.sign = try allocator.dupe(u8, v);
                try actions.append(allocator, action);
            }
            data.actions = try actions.toOwnedSlice(allocator);
        }
    }

    return data;
}

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |val| {
        if (val == .string) return val.string;
    }
    return null;
}
