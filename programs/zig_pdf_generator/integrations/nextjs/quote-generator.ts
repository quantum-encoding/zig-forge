/**
 * CRG Direct Quote PDF Generator
 *
 * Generates professional quote PDFs from structured data.
 * TypeScript version for Next.js integration.
 */

import type {
  QuoteData,
  PresentationTemplate,
  PresentationPage,
  PresentationElement,
  CompanyInfo,
  BrandColors,
  ZigPdfModule
} from './types';

// ============================================================================
// Default Company Configuration
// ============================================================================

export const DEFAULT_COMPANY: Required<CompanyInfo> = {
  name: 'CRG DIRECT',
  legalName: 'CRG DIRECT LTD',
  address: 'Unit 7, Solent Business Park, Whiteley, Hampshire PO15 7FJ',
  phone: '0800 123 4567',
  email: 'hello@crgdirect.co.uk',
  website: 'crgdirect.co.uk',
  companyReg: '12345678',
  vatNumber: 'GB 123 4567 89',
  mcsNumber: 'NAP-12345',
  tagline: "Powering Hampshire's Sustainable Future",

  colors: {
    primary: '#10B981',
    primaryDark: '#059669',
    primaryDarker: '#047857',
    primaryDarkest: '#065F46',
    dark: '#111827',
    darkMid: '#1F2937',
    darkLight: '#374151',
    gray: '#6B7280',
    grayLight: '#9CA3AF',
    grayLighter: '#D1D5DB',
    background: '#F9FAFB',
    backgroundGreen: '#ECFDF5',
    backgroundGreenLight: '#F0FDF4',
    border: '#E5E7EB',
    borderGreen: '#A7F3D0',
    white: '#ffffff',
    success: '#10B981',
    accent: '#6EE7B7'
  },

  accreditations: [
    'MCS Certified Installer (Solar & Heat Pumps)',
    'RECC Member (Consumer Code)',
    'TrustMark Government Endorsed',
    'NAPIT Approved Contractor',
    'Tesla Powerwall Certified',
    'GivEnergy Approved Installer',
    'NICEIC Approved Contractor',
    'Gas Safe Registered (Heat Pumps)'
  ],

  stats: {
    installations: '2,500+',
    rating: '4.9/5',
    experience: '15 Years',
    warranty: '25 Year'
  }
};

// ============================================================================
// Helper Functions
// ============================================================================

/**
 * Format a number as GBP currency
 */
export function formatCurrency(amount: number): string {
  return `£${amount.toLocaleString('en-GB', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2
  })}`;
}

/**
 * Calculate deposit amount (25%)
 */
export function calculateDeposit(total: number): number {
  return total * 0.25;
}

/**
 * Calculate total from line items
 */
export function calculateTotal(data: QuoteData): number {
  return data.lineItems.reduce((sum, item) => sum + item.amount, 0);
}

/**
 * Get a testimonial
 */
function getTestimonial(): { text: string; author: string } {
  return {
    text: '"Brilliant service from start to finish. The team were professional, tidy, and explained everything clearly. Our electricity bills have dropped by 70% since installation. Highly recommend!"',
    author: 'David & Sarah T., Eastleigh (Dec 2025)'
  };
}

// ============================================================================
// Page Generators
// ============================================================================

function generateCoverPage(
  data: QuoteData,
  company: Required<CompanyInfo>,
  colors: BrandColors
): PresentationPage {
  const systemTitle = data.system.solar && data.system.battery
    ? 'Solar PV & Battery Storage'
    : data.system.solar
      ? 'Solar PV System'
      : data.system.battery
        ? 'Battery Storage System'
        : data.system.heatPump
          ? 'Heat Pump System'
          : 'Renewable Energy System';

  return {
    background_color: colors.dark,
    elements: [
      { type: 'shape', shape: 'rectangle', x: 0, y: 0, width: 842, height: 595, fill_color: colors.dark },
      { type: 'shape', shape: 'rectangle', x: 0, y: 480, width: 842, height: 115, fill_color: colors.primary },
      { type: 'shape', shape: 'line', x: 60, y: 140, width: 100, height: 0, stroke_color: colors.primary, stroke_width: 4 },

      { type: 'text', content: 'CRG', x: 60, y: 80, font_size: 48, font_weight: 'bold', color: colors.primary },
      { type: 'text', content: 'DIRECT', x: 155, y: 80, font_size: 48, font_weight: 'bold', color: colors.white },
      { type: 'text', content: 'RENEWABLE ENERGY SOLUTIONS', x: 60, y: 115, font_size: 14, color: colors.accent, font_weight: 'bold' },

      { type: 'text', content: 'YOUR PERSONALISED QUOTE', x: 60, y: 180, font_size: 12, color: colors.grayLight, font_weight: 'bold' },
      { type: 'text', content: systemTitle, x: 60, y: 220, font_size: 36, font_weight: 'bold', color: colors.white },
      { type: 'text', content: 'Installation Package', x: 60, y: 260, font_size: 36, font_weight: 'bold', color: colors.primary },

      { type: 'shape', shape: 'rectangle', x: 60, y: 310, width: 200, height: 80, fill_color: colors.darkMid, stroke_color: colors.darkLight, stroke_width: 1 },
      { type: 'text', content: 'PREPARED FOR', x: 75, y: 328, font_size: 10, color: colors.gray },
      { type: 'text', content: data.customer.name, x: 75, y: 355, font_size: 16, font_weight: 'bold', color: colors.white },

      { type: 'shape', shape: 'rectangle', x: 280, y: 310, width: 200, height: 80, fill_color: colors.darkMid, stroke_color: colors.darkLight, stroke_width: 1 },
      { type: 'text', content: 'PROPERTY', x: 295, y: 328, font_size: 10, color: colors.gray },
      { type: 'text', content: data.customer.address, x: 295, y: 355, font_size: 14, font_weight: 'bold', color: colors.white, max_width: 180 },

      { type: 'shape', shape: 'rectangle', x: 500, y: 310, width: 200, height: 80, fill_color: colors.darkMid, stroke_color: colors.darkLight, stroke_width: 1 },
      { type: 'text', content: 'QUOTE REF', x: 515, y: 328, font_size: 10, color: colors.gray },
      { type: 'text', content: data.quoteRef, x: 515, y: 355, font_size: 16, font_weight: 'bold', color: colors.primary },

      { type: 'shape', shape: 'rectangle', x: 60, y: 410, width: 150, height: 50, fill_color: colors.darkMid, stroke_color: colors.darkLight, stroke_width: 1 },
      { type: 'text', content: 'DATE', x: 75, y: 425, font_size: 9, color: colors.gray },
      { type: 'text', content: data.date, x: 75, y: 445, font_size: 12, font_weight: 'bold', color: colors.white },

      { type: 'shape', shape: 'rectangle', x: 225, y: 410, width: 150, height: 50, fill_color: colors.darkMid, stroke_color: colors.darkLight, stroke_width: 1 },
      { type: 'text', content: 'VALID UNTIL', x: 240, y: 425, font_size: 9, color: colors.gray },
      { type: 'text', content: data.validUntil, x: 240, y: 445, font_size: 12, font_weight: 'bold', color: colors.white },

      { type: 'shape', shape: 'rectangle', x: 390, y: 410, width: 150, height: 50, fill_color: colors.darkMid, stroke_color: colors.darkLight, stroke_width: 1 },
      { type: 'text', content: 'YOUR ADVISOR', x: 405, y: 425, font_size: 9, color: colors.gray },
      { type: 'text', content: data.advisor, x: 405, y: 445, font_size: 12, font_weight: 'bold', color: colors.white },

      { type: 'text', content: company.tagline, x: 60, y: 520, font_size: 22, font_weight: 'bold', color: colors.dark },
      { type: 'text', content: `${company.website}  |  ${company.phone}  |  ${company.email}`, x: 60, y: 555, font_size: 12, color: colors.primaryDarkest },
      { type: 'text', content: 'MCS Certified  |  RECC Member  |  TrustMark Registered', x: 782, y: 555, font_size: 10, color: colors.primaryDarkest, align: 'right' }
    ]
  };
}

function generateWhyUsPage(
  data: QuoteData,
  company: Required<CompanyInfo>,
  colors: BrandColors
): PresentationPage {
  const testimonial = getTestimonial();

  return {
    background_color: colors.white,
    elements: [
      { type: 'shape', shape: 'rectangle', x: 0, y: 0, width: 842, height: 55, fill_color: colors.dark },
      { type: 'text', content: 'CRG DIRECT', x: 60, y: 33, font_size: 14, font_weight: 'bold', color: colors.primary },
      { type: 'text', content: 'Why Choose Us', x: 782, y: 33, font_size: 11, color: colors.accent, align: 'right' },

      { type: 'text', content: 'Why CRG Direct?', x: 60, y: 95, font_size: 26, font_weight: 'bold', color: colors.dark },
      { type: 'shape', shape: 'line', x: 60, y: 108, width: 60, height: 0, stroke_color: colors.primary, stroke_width: 3 },
      { type: 'text', content: "Hampshire's trusted renewable energy experts. We've helped over 2,500 homeowners reduce their energy bills and carbon footprint with quality solar, battery, and heat pump installations.", x: 60, y: 135, font_size: 11, color: colors.darkLight, max_width: 360 },

      { type: 'shape', shape: 'rectangle', x: 60, y: 195, width: 170, height: 90, fill_color: colors.backgroundGreen, stroke_color: colors.borderGreen, stroke_width: 1 },
      { type: 'text', content: company.stats.installations, x: 145, y: 230, font_size: 28, font_weight: 'bold', color: colors.primaryDark, align: 'center' },
      { type: 'text', content: 'Installations', x: 145, y: 262, font_size: 11, color: colors.primaryDarkest, align: 'center' },

      { type: 'shape', shape: 'rectangle', x: 245, y: 195, width: 170, height: 90, fill_color: colors.backgroundGreen, stroke_color: colors.borderGreen, stroke_width: 1 },
      { type: 'text', content: company.stats.rating, x: 330, y: 230, font_size: 28, font_weight: 'bold', color: colors.primaryDark, align: 'center' },
      { type: 'text', content: 'Customer Rating', x: 330, y: 262, font_size: 11, color: colors.primaryDarkest, align: 'center' },

      { type: 'shape', shape: 'rectangle', x: 60, y: 300, width: 170, height: 90, fill_color: colors.backgroundGreen, stroke_color: colors.borderGreen, stroke_width: 1 },
      { type: 'text', content: company.stats.experience, x: 145, y: 335, font_size: 28, font_weight: 'bold', color: colors.primaryDark, align: 'center' },
      { type: 'text', content: 'Experience', x: 145, y: 367, font_size: 11, color: colors.primaryDarkest, align: 'center' },

      { type: 'shape', shape: 'rectangle', x: 245, y: 300, width: 170, height: 90, fill_color: colors.backgroundGreen, stroke_color: colors.borderGreen, stroke_width: 1 },
      { type: 'text', content: company.stats.warranty, x: 330, y: 335, font_size: 28, font_weight: 'bold', color: colors.primaryDark, align: 'center' },
      { type: 'text', content: 'Panel Warranty', x: 330, y: 367, font_size: 11, color: colors.primaryDarkest, align: 'center' },

      { type: 'shape', shape: 'rectangle', x: 450, y: 90, width: 340, height: 310, fill_color: colors.dark, stroke_color: colors.darkMid, stroke_width: 2 },
      { type: 'text', content: 'Our Accreditations', x: 470, y: 120, font_size: 15, font_weight: 'bold', color: colors.white },
      { type: 'shape', shape: 'line', x: 470, y: 133, width: 50, height: 0, stroke_color: colors.primary, stroke_width: 2 },
      { type: 'bullet_list', x: 470, y: 158, font_size: 10, color: colors.grayLighter, bullet_color: colors.primary, line_spacing: 12, indent: 14, items: company.accreditations },
      { type: 'text', content: 'Insurance Cover', x: 470, y: 310, font_size: 11, font_weight: 'bold', color: colors.primary },
      { type: 'text', content: '£5M Public Liability', x: 470, y: 330, font_size: 10, color: colors.grayLight },
      { type: 'text', content: '10 Year Workmanship Warranty', x: 470, y: 348, font_size: 10, color: colors.grayLight },
      { type: 'text', content: 'IWA Insurance-Backed Guarantee', x: 470, y: 366, font_size: 10, color: colors.grayLight },

      { type: 'shape', shape: 'rectangle', x: 60, y: 415, width: 722, height: 65, fill_color: colors.backgroundGreenLight, stroke_color: colors.primary, stroke_width: 1 },
      { type: 'text', content: 'CUSTOMER TESTIMONIAL', x: 80, y: 433, font_size: 9, font_weight: 'bold', color: colors.primaryDarkest },
      { type: 'text', content: testimonial.text, x: 80, y: 453, font_size: 10, font_style: 'italic', color: colors.primaryDarker, max_width: 680 },
      { type: 'text', content: `— ${testimonial.author}`, x: 762, y: 467, font_size: 9, color: colors.primaryDarkest, align: 'right' },

      { type: 'shape', shape: 'line', x: 60, y: 505, width: 722, height: 0, stroke_color: colors.border, stroke_width: 1 },
      { type: 'text', content: 'Page 2 of 5', x: 421, y: 525, font_size: 10, color: colors.grayLight, align: 'center' }
    ]
  };
}

function generateSystemPage(
  data: QuoteData,
  company: Required<CompanyInfo>,
  colors: BrandColors
): PresentationPage {
  const elements: PresentationElement[] = [
    { type: 'shape', shape: 'rectangle', x: 0, y: 0, width: 842, height: 55, fill_color: colors.dark },
    { type: 'text', content: 'CRG DIRECT', x: 60, y: 33, font_size: 14, font_weight: 'bold', color: colors.primary },
    { type: 'text', content: 'Your System', x: 782, y: 33, font_size: 11, color: colors.accent, align: 'right' },

    { type: 'text', content: 'Your Recommended System', x: 60, y: 95, font_size: 26, font_weight: 'bold', color: colors.dark },
    { type: 'shape', shape: 'line', x: 60, y: 108, width: 60, height: 0, stroke_color: colors.primary, stroke_width: 3 },
    { type: 'text', content: 'Based on your property survey and energy usage, we recommend the following system to maximise your savings and self-consumption.', x: 60, y: 135, font_size: 11, color: colors.darkLight, max_width: 720 }
  ];

  const yOffset = 175;

  if (data.system.solar) {
    const solar = data.system.solar;
    elements.push(
      { type: 'shape', shape: 'rectangle', x: 60, y: yOffset, width: 350, height: 180, fill_color: colors.background, stroke_color: colors.border, stroke_width: 1 },
      { type: 'text', content: 'SOLAR PV SYSTEM', x: 80, y: yOffset + 23, font_size: 11, font_weight: 'bold', color: colors.primary },
      { type: 'bullet_list', x: 80, y: yOffset + 45, font_size: 10, color: colors.darkLight, bullet_color: colors.primary, line_spacing: 10, indent: 12, items: [
        solar.panels,
        `${solar.size} Total System Size`,
        solar.inverter,
        `${solar.orientation} roof, ${solar.pitch} pitch`,
        `Estimated annual yield: ${solar.yield}`
      ]},
      { type: 'text', content: formatCurrency(solar.price), x: 390, y: yOffset + 163, font_size: 18, font_weight: 'bold', color: colors.dark, align: 'right' }
    );
  }

  if (data.system.battery) {
    const battery = data.system.battery;
    const batteryX = data.system.solar ? 430 : 60;
    elements.push(
      { type: 'shape', shape: 'rectangle', x: batteryX, y: yOffset, width: 350, height: 180, fill_color: colors.background, stroke_color: colors.border, stroke_width: 1 },
      { type: 'text', content: 'BATTERY STORAGE', x: batteryX + 20, y: yOffset + 23, font_size: 11, font_weight: 'bold', color: colors.primary },
      { type: 'bullet_list', x: batteryX + 20, y: yOffset + 45, font_size: 10, color: colors.darkLight, bullet_color: colors.primary, line_spacing: 10, indent: 12, items: [
        battery.model,
        battery.capacity,
        battery.warranty,
        ...battery.features
      ]},
      { type: 'text', content: formatCurrency(battery.price), x: batteryX + 330, y: yOffset + 163, font_size: 18, font_weight: 'bold', color: colors.dark, align: 'right' }
    );
  }

  if (data.system.installation && data.system.installation.length > 0) {
    const instY = 370;
    const halfItems = Math.ceil(data.system.installation.length / 2);
    const leftItems = data.system.installation.slice(0, halfItems);
    const rightItems = data.system.installation.slice(halfItems);

    elements.push(
      { type: 'shape', shape: 'rectangle', x: 60, y: instY, width: 720, height: 100, fill_color: colors.background, stroke_color: colors.border, stroke_width: 1 },
      { type: 'text', content: 'INSTALLATION & ANCILLARY', x: 80, y: instY + 23, font_size: 11, font_weight: 'bold', color: colors.primary },
      { type: 'bullet_list', x: 80, y: instY + 45, font_size: 10, color: colors.darkLight, bullet_color: colors.primary, line_spacing: 10, indent: 12, items: leftItems }
    );

    if (rightItems.length > 0) {
      elements.push(
        { type: 'bullet_list', x: 420, y: instY + 45, font_size: 10, color: colors.darkLight, bullet_color: colors.primary, line_spacing: 10, indent: 12, items: rightItems }
      );
    }
  }

  elements.push(
    { type: 'shape', shape: 'line', x: 60, y: 505, width: 722, height: 0, stroke_color: colors.border, stroke_width: 1 },
    { type: 'text', content: 'Page 3 of 5', x: 421, y: 525, font_size: 10, color: colors.grayLight, align: 'center' }
  );

  return { background_color: colors.white, elements };
}

function generateInvestmentPage(
  data: QuoteData,
  company: Required<CompanyInfo>,
  colors: BrandColors
): PresentationPage {
  const subtotal = calculateTotal(data);
  const vat = 0;
  const total = subtotal + vat;

  const tableRows = data.lineItems.map(item => [
    item.description,
    formatCurrency(item.amount)
  ]);

  return {
    background_color: colors.white,
    elements: [
      { type: 'shape', shape: 'rectangle', x: 0, y: 0, width: 842, height: 55, fill_color: colors.dark },
      { type: 'text', content: 'CRG DIRECT', x: 60, y: 33, font_size: 14, font_weight: 'bold', color: colors.primary },
      { type: 'text', content: 'Investment & Savings', x: 782, y: 33, font_size: 11, color: colors.accent, align: 'right' },

      { type: 'text', content: 'Your Investment', x: 60, y: 95, font_size: 26, font_weight: 'bold', color: colors.dark },
      { type: 'shape', shape: 'line', x: 60, y: 108, width: 60, height: 0, stroke_color: colors.primary, stroke_width: 3 },

      {
        type: 'table',
        x: 60,
        y: 130,
        columns: ['Description', 'Amount'],
        column_widths: [520, 140],
        rows: tableRows,
        header_bg_color: colors.dark,
        header_text_color: colors.white,
        row_bg_color: colors.white,
        alt_row_bg_color: colors.background,
        text_color: colors.darkLight,
        border_color: colors.border,
        font_size: 10,
        header_font_size: 11,
        padding: 10,
        row_height: 28,
        header_height: 32
      },

      { type: 'text', content: '* 0% VAT applies to residential solar installations under the Energy Saving Materials scheme', x: 60, y: 460, font_size: 9, font_style: 'italic', color: colors.gray },

      { type: 'shape', shape: 'rectangle', x: 460, y: 480, width: 320, height: 90, fill_color: colors.dark, stroke_color: colors.darkMid, stroke_width: 2 },
      { type: 'text', content: 'Subtotal', x: 480, y: 500, font_size: 11, color: colors.grayLight },
      { type: 'text', content: formatCurrency(subtotal), x: 760, y: 500, font_size: 11, color: colors.white, align: 'right' },
      { type: 'text', content: 'VAT (0% - Energy Saving Materials)', x: 480, y: 520, font_size: 11, color: colors.primary },
      { type: 'text', content: '£0.00', x: 760, y: 520, font_size: 11, color: colors.primary, align: 'right' },
      { type: 'shape', shape: 'line', x: 480, y: 535, width: 280, height: 0, stroke_color: colors.darkLight, stroke_width: 1 },
      { type: 'text', content: 'TOTAL', x: 480, y: 555, font_size: 14, font_weight: 'bold', color: colors.white },
      { type: 'text', content: formatCurrency(total), x: 760, y: 555, font_size: 16, font_weight: 'bold', color: colors.primary, align: 'right' }
    ]
  };
}

function generateAcceptancePage(
  data: QuoteData,
  company: Required<CompanyInfo>,
  colors: BrandColors
): PresentationPage {
  const total = calculateTotal(data);
  const deposit = calculateDeposit(total);

  return {
    background_color: colors.white,
    elements: [
      { type: 'shape', shape: 'rectangle', x: 0, y: 0, width: 842, height: 55, fill_color: colors.dark },
      { type: 'text', content: 'CRG DIRECT', x: 60, y: 33, font_size: 14, font_weight: 'bold', color: colors.primary },
      { type: 'text', content: 'Accept & Proceed', x: 782, y: 33, font_size: 11, color: colors.accent, align: 'right' },

      { type: 'text', content: 'Your Estimated Savings', x: 60, y: 95, font_size: 26, font_weight: 'bold', color: colors.dark },
      { type: 'shape', shape: 'line', x: 60, y: 108, width: 60, height: 0, stroke_color: colors.primary, stroke_width: 3 },

      { type: 'shape', shape: 'rectangle', x: 60, y: 130, width: 175, height: 85, fill_color: colors.primary },
      { type: 'text', content: 'YEAR 1 SAVINGS', x: 80, y: 150, font_size: 9, color: colors.backgroundGreen },
      { type: 'text', content: formatCurrency(data.savings.year1), x: 80, y: 190, font_size: 28, font_weight: 'bold', color: colors.white },

      { type: 'shape', shape: 'rectangle', x: 250, y: 130, width: 175, height: 85, fill_color: colors.primaryDark },
      { type: 'text', content: '25 YEAR SAVINGS', x: 270, y: 150, font_size: 9, color: colors.backgroundGreen },
      { type: 'text', content: formatCurrency(data.savings.lifetime), x: 270, y: 190, font_size: 28, font_weight: 'bold', color: colors.white },

      { type: 'shape', shape: 'rectangle', x: 440, y: 130, width: 175, height: 85, fill_color: colors.primaryDarker },
      { type: 'text', content: 'PAYBACK PERIOD', x: 460, y: 150, font_size: 9, color: colors.backgroundGreen },
      { type: 'text', content: `${data.savings.paybackYears} Years`, x: 460, y: 190, font_size: 28, font_weight: 'bold', color: colors.white },

      { type: 'shape', shape: 'rectangle', x: 630, y: 130, width: 150, height: 85, fill_color: colors.primaryDarkest },
      { type: 'text', content: 'CO2 SAVED/YR', x: 650, y: 150, font_size: 9, color: colors.backgroundGreen },
      { type: 'text', content: `${data.savings.co2Tonnes} t`, x: 650, y: 190, font_size: 28, font_weight: 'bold', color: colors.white },

      { type: 'text', content: '* Savings based on current energy prices (34p/kWh), 80% self-consumption, and SEG export at 15p/kWh', x: 60, y: 230, font_size: 9, font_style: 'italic', color: colors.gray },

      { type: 'shape', shape: 'rectangle', x: 60, y: 255, width: 722, height: 165, fill_color: colors.background, stroke_color: colors.dark, stroke_width: 2 },
      { type: 'text', content: 'ACCEPTANCE', x: 80, y: 280, font_size: 14, font_weight: 'bold', color: colors.dark },
      { type: 'text', content: 'I/We accept this quotation and authorise CRG Direct to proceed with the installation as described.', x: 80, y: 305, font_size: 10, color: colors.darkLight },
      { type: 'text', content: `A 25% deposit (${formatCurrency(deposit)}) is required to secure your installation date. Balance due on completion.`, x: 80, y: 322, font_size: 10, color: colors.darkLight },
      { type: 'text', content: 'Signed: ___________________________________________', x: 80, y: 360, font_size: 10, color: colors.darkLight },
      { type: 'text', content: 'Date: ___________________', x: 480, y: 360, font_size: 10, color: colors.darkLight },
      { type: 'text', content: 'Print Name: ________________________________________', x: 80, y: 390, font_size: 10, color: colors.darkLight },

      { type: 'shape', shape: 'rectangle', x: 0, y: 440, width: 842, height: 155, fill_color: colors.dark },
      { type: 'text', content: company.legalName, x: 60, y: 470, font_size: 14, font_weight: 'bold', color: colors.primary },
      { type: 'text', content: company.address, x: 60, y: 495, font_size: 10, color: colors.grayLight },
      { type: 'text', content: `Company Reg: ${company.companyReg}  |  VAT: ${company.vatNumber}  |  MCS: ${company.mcsNumber}`, x: 60, y: 515, font_size: 10, color: colors.grayLight },
      { type: 'text', content: `Tel: ${company.phone}  |  Email: ${company.email}  |  Web: ${company.website}`, x: 60, y: 535, font_size: 10, color: colors.grayLight },

      { type: 'text', content: 'Next Steps', x: 550, y: 470, font_size: 12, font_weight: 'bold', color: colors.white },
      { type: 'bullet_list', x: 550, y: 492, font_size: 9, color: colors.grayLighter, bullet_color: colors.primary, line_spacing: 10, indent: 12, items: [
        'Sign and return this quote',
        'Pay 25% deposit to confirm',
        "We'll schedule your install date",
        'Installation typically 1-2 days'
      ]},

      { type: 'text', content: 'Page 5 of 5', x: 782, y: 575, font_size: 10, color: colors.gray, align: 'right' }
    ]
  };
}

// ============================================================================
// Main Export Functions
// ============================================================================

/**
 * Generate the complete quote template JSON
 */
export function generateQuoteTemplate(data: QuoteData): PresentationTemplate {
  const company: Required<CompanyInfo> = {
    ...DEFAULT_COMPANY,
    ...data.company,
    colors: { ...DEFAULT_COMPANY.colors, ...data.company?.colors },
    stats: { ...DEFAULT_COMPANY.stats, ...data.company?.stats }
  };
  const colors = company.colors;

  return {
    page_size: { width: 842, height: 595 },
    pages: [
      generateCoverPage(data, company, colors),
      generateWhyUsPage(data, company, colors),
      generateSystemPage(data, company, colors),
      generateInvestmentPage(data, company, colors),
      generateAcceptancePage(data, company, colors)
    ]
  };
}

/**
 * Generate PDF bytes from quote data
 */
export function generateQuotePdf(zigPdf: ZigPdfModule, data: QuoteData): Uint8Array {
  const template = generateQuoteTemplate(data);
  const jsonString = JSON.stringify(template);
  return zigPdf.generatePresentation(jsonString);
}

/**
 * Trigger PDF download in browser
 */
export function downloadQuotePdf(
  zigPdf: ZigPdfModule,
  data: QuoteData,
  filename?: string
): void {
  const pdfBytes = generateQuotePdf(zigPdf, data);
  const blob = new Blob([pdfBytes], { type: 'application/pdf' });
  const url = URL.createObjectURL(blob);

  const link = document.createElement('a');
  link.href = url;
  link.download = filename || `${data.quoteRef}.pdf`;
  document.body.appendChild(link);
  link.click();
  document.body.removeChild(link);

  URL.revokeObjectURL(url);
}

/**
 * Open PDF in new tab
 */
export function openQuotePdf(zigPdf: ZigPdfModule, data: QuoteData): void {
  const pdfBytes = generateQuotePdf(zigPdf, data);
  const blob = new Blob([pdfBytes], { type: 'application/pdf' });
  const url = URL.createObjectURL(blob);
  window.open(url, '_blank');
}
