# ZigPDF Next.js Integration

High-performance PDF generation for Next.js applications using WebAssembly.

## Installation

### 1. Copy the Integration Files

Copy the `integrations/nextjs` folder to your Next.js project:

```bash
cp -r integrations/nextjs /path/to/your/nextjs-project/src/lib/zigpdf
```

### 2. Build the WASM Module

Build the ZigPDF WASM binary:

```bash
cd programs/zig_pdf_generator
zig build -Dtarget=wasm32-wasi -Doptimize=ReleaseSmall
```

Or use the provided build script (if available):

```bash
./build-wasm.sh
```

### 3. Copy WASM to Public Folder

```bash
cp zig-out/lib/zigpdf.wasm /path/to/your/nextjs-project/public/
```

### 4. Update TypeScript Config (if needed)

Ensure your `tsconfig.json` includes:

```json
{
  "compilerOptions": {
    "moduleResolution": "bundler",
    "esModuleInterop": true
  }
}
```

## Usage

### Client-Side: React Hook

```tsx
'use client';

import { useZigPdf } from '@/lib/zigpdf';
import type { QuoteData } from '@/lib/zigpdf';

export function QuoteGenerator() {
  const { isLoaded, isLoading, error, downloadQuote } = useZigPdf();

  const quoteData: QuoteData = {
    customer: {
      name: 'Mr & Mrs Johnson',
      address: '42 Oak Lane, Southampton'
    },
    quoteRef: 'CRG-2026-00847',
    date: '1st February 2026',
    validUntil: '1st March 2026',
    advisor: 'James Mitchell',
    system: {
      solar: {
        panels: '12 x JA Solar 440W All-Black Panels',
        size: '5.28kWp',
        inverter: 'GivEnergy 5.0kW Hybrid Inverter',
        orientation: 'South-facing',
        pitch: '35°',
        yield: '4,800 kWh',
        price: 6480
      },
      battery: {
        model: 'GivEnergy 9.5kWh Battery',
        capacity: '9.5kWh usable capacity',
        warranty: '10 year manufacturer warranty',
        features: ['Smart energy management', 'EV charging ready'],
        price: 4250
      },
      installation: [
        'Full scaffolding and site setup',
        'Electrical consumer unit upgrade',
        'DNO G99 notification and approval',
        'MCS certification and handover pack'
      ]
    },
    lineItems: [
      { description: '12 x JA Solar 440W Panels', amount: 3960 },
      { description: 'GivEnergy 5.0kW Hybrid Inverter', amount: 1520 },
      { description: 'GivEnergy 9.5kWh Battery', amount: 3450 },
      { description: 'Installation & Accessories', amount: 3980 }
    ],
    savings: {
      year1: 1420,
      lifetime: 42500,
      paybackYears: 9.1,
      co2Tonnes: 2.1
    }
  };

  if (isLoading) {
    return <div>Loading PDF engine...</div>;
  }

  if (error) {
    return <div>Error: {error.message}</div>;
  }

  return (
    <button
      onClick={() => downloadQuote(quoteData)}
      disabled={!isLoaded}
      className="bg-green-500 text-white px-6 py-3 rounded-lg"
    >
      Download Quote PDF
    </button>
  );
}
```

### Client-Side: Pre-built Button Component

```tsx
'use client';

import { QuotePdfButton } from '@/lib/zigpdf';

export function QuotePage({ quoteData }) {
  return (
    <QuotePdfButton
      quoteData={quoteData}
      label="Download Your Quote"
      variant="primary"
      onSuccess={() => console.log('PDF downloaded!')}
      onError={(error) => console.error('Failed:', error)}
    />
  );
}
```

### Client-Side: Context Provider

For sharing the WASM module across your app:

```tsx
// app/layout.tsx
import { ZigPdfProvider } from '@/lib/zigpdf';

export default function RootLayout({ children }) {
  return (
    <html>
      <body>
        <ZigPdfProvider wasmUrl="/zigpdf.wasm">
          {children}
        </ZigPdfProvider>
      </body>
    </html>
  );
}

// Any component
'use client';
import { useZigPdfContext } from '@/lib/zigpdf';

function MyComponent() {
  const { downloadQuote, isLoaded } = useZigPdfContext();
  // ...
}
```

### Server-Side: API Route (App Router)

```ts
// app/api/quote/route.ts
import { generateQuoteHandler } from '@/lib/zigpdf';

export const POST = generateQuoteHandler;
```

Call from client:

```ts
const response = await fetch('/api/quote', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(quoteData)
});

const pdfBlob = await response.blob();
const url = URL.createObjectURL(pdfBlob);
window.open(url);
```

### Server-Side: API Route (Pages Router)

```ts
// pages/api/quote.ts
import { generateQuoteApiHandler } from '@/lib/zigpdf';

export default generateQuoteApiHandler;
```

### Server-Side: Direct Generation

```ts
import { loadZigPdfServer, generateQuotePdf } from '@/lib/zigpdf';

async function generateQuote(quoteData: QuoteData) {
  const zigPdf = await loadZigPdfServer();
  const pdfBytes = generateQuotePdf(zigPdf, quoteData);

  // Save to file or storage
  await fs.writeFile(`quotes/${quoteData.quoteRef}.pdf`, pdfBytes);
}
```

## API Reference

### `useZigPdf(options?)`

React hook for PDF generation.

**Options:**
- `wasmUrl?: string` - URL to WASM file (default: `/zigpdf.wasm`)
- `forceReload?: boolean` - Force reload the WASM module

**Returns:**
- `isLoaded: boolean` - Whether the WASM module is loaded
- `isLoading: boolean` - Whether the module is loading
- `error: Error | null` - Any loading error
- `module: ZigPdfModule | null` - The raw WASM module
- `generateQuote(data)` - Generate PDF bytes
- `downloadQuote(data, filename?)` - Generate and download PDF
- `openQuote(data)` - Generate and open PDF in new tab
- `getTemplate(data)` - Get JSON template without generating

### `generateQuoteTemplate(data)`

Generate the JSON template from quote data.

### `generateQuotePdf(module, data)`

Generate PDF bytes from quote data.

### `loadZigPdf(options?)`

Load the WASM module (browser).

### `loadZigPdfServer(wasmPath?)`

Load the WASM module (Node.js / server).

## Type Reference

See `types.ts` for complete type definitions:

- `QuoteData` - Complete quote data structure
- `CustomerInfo` - Customer details
- `SolarSystem` - Solar PV configuration
- `BatterySystem` - Battery storage configuration
- `LineItem` - Pricing line item
- `SavingsEstimate` - Savings projections

## Customization

### Custom Company Branding

Override the default company info:

```ts
const quoteData: QuoteData = {
  // ... other fields
  company: {
    name: 'My Company',
    tagline: 'Your tagline here',
    colors: {
      primary: '#FF6B00',
      // ... other colors
    }
  }
};
```

### Custom Templates

For completely custom layouts, generate your own template:

```ts
const { generateFromTemplate } = useZigPdf();

const customTemplate = {
  page_size: { width: 842, height: 595 },
  pages: [
    {
      background_color: '#ffffff',
      elements: [
        {
          type: 'text',
          content: 'My Custom PDF',
          x: 100,
          y: 100,
          font_size: 48,
          color: '#000000'
        }
      ]
    }
  ]
};

const pdfBytes = generateFromTemplate(customTemplate);
```

## Performance

- WASM module is ~200KB gzipped
- Loads once and caches in memory
- PDF generation is instantaneous (<50ms for 5-page quote)
- No server round-trip required for client-side generation

## Browser Support

- Chrome 57+
- Firefox 52+
- Safari 11+
- Edge 16+

All modern browsers with WebAssembly support.

## Troubleshooting

### WASM fails to load

1. Ensure `zigpdf.wasm` is in your `public` folder
2. Check browser console for CORS errors
3. Verify the file is served with correct MIME type (`application/wasm`)

### TypeScript errors

Ensure your `tsconfig.json` has:
```json
{
  "compilerOptions": {
    "strict": true,
    "esModuleInterop": true
  }
}
```

### Server-side generation fails

For Node.js API routes, ensure the WASM file path is correct:
```ts
const zigPdf = await loadZigPdfServer('./public/zigpdf.wasm');
```
