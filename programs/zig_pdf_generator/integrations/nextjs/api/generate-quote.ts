/**
 * API Route Handler for Quote PDF Generation
 *
 * Server-side PDF generation for Next.js API routes.
 * Can be used with both Pages Router and App Router.
 *
 * Usage (App Router):
 * ```ts
 * // app/api/quote/route.ts
 * import { generateQuoteHandler } from '@/lib/zigpdf/api/generate-quote';
 * export const POST = generateQuoteHandler;
 * ```
 *
 * Usage (Pages Router):
 * ```ts
 * // pages/api/quote.ts
 * import { generateQuoteApiHandler } from '@/lib/zigpdf/api/generate-quote';
 * export default generateQuoteApiHandler;
 * ```
 */

import { loadZigPdfServer } from '../zigpdf-loader';
import { generateQuotePdf } from '../quote-generator';
import type { QuoteData } from '../types';

// ============================================================================
// App Router Handler (Next.js 13+)
// ============================================================================

/**
 * App Router POST handler for quote generation
 */
export async function generateQuoteHandler(request: Request): Promise<Response> {
  try {
    // Parse request body
    const body = await request.json();
    const quoteData = body as QuoteData;

    // Validate required fields
    if (!quoteData.customer?.name || !quoteData.quoteRef) {
      return new Response(
        JSON.stringify({ error: 'Missing required fields: customer.name, quoteRef' }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      );
    }

    // Load WASM module
    const zigPdf = await loadZigPdfServer();

    // Generate PDF
    const pdfBytes = generateQuotePdf(zigPdf, quoteData);

    // Return PDF
    return new Response(pdfBytes, {
      status: 200,
      headers: {
        'Content-Type': 'application/pdf',
        'Content-Disposition': `attachment; filename="${quoteData.quoteRef}.pdf"`,
        'Content-Length': pdfBytes.length.toString()
      }
    });
  } catch (error) {
    console.error('Quote generation error:', error);
    return new Response(
      JSON.stringify({
        error: 'Failed to generate quote',
        message: error instanceof Error ? error.message : String(error)
      }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    );
  }
}

/**
 * App Router GET handler for quote generation (via query params)
 */
export async function generateQuoteGetHandler(request: Request): Promise<Response> {
  try {
    const url = new URL(request.url);
    const quoteId = url.searchParams.get('id');

    if (!quoteId) {
      return new Response(
        JSON.stringify({ error: 'Missing quote ID' }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      );
    }

    // In a real app, fetch quote data from database here
    // const quoteData = await getQuoteFromDatabase(quoteId);

    return new Response(
      JSON.stringify({ error: 'Quote fetching not implemented - use POST with quote data' }),
      { status: 501, headers: { 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Quote generation error:', error);
    return new Response(
      JSON.stringify({ error: 'Failed to generate quote' }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    );
  }
}

// ============================================================================
// Pages Router Handler (Next.js 12 / Legacy)
// ============================================================================

import type { NextApiRequest, NextApiResponse } from 'next';

/**
 * Pages Router API handler for quote generation
 */
export async function generateQuoteApiHandler(
  req: NextApiRequest,
  res: NextApiResponse
): Promise<void> {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }

  try {
    const quoteData = req.body as QuoteData;

    // Validate required fields
    if (!quoteData.customer?.name || !quoteData.quoteRef) {
      res.status(400).json({ error: 'Missing required fields: customer.name, quoteRef' });
      return;
    }

    // Load WASM module
    const zigPdf = await loadZigPdfServer();

    // Generate PDF
    const pdfBytes = generateQuotePdf(zigPdf, quoteData);

    // Set headers and send PDF
    res.setHeader('Content-Type', 'application/pdf');
    res.setHeader('Content-Disposition', `attachment; filename="${quoteData.quoteRef}.pdf"`);
    res.setHeader('Content-Length', pdfBytes.length);
    res.status(200).send(Buffer.from(pdfBytes));
  } catch (error) {
    console.error('Quote generation error:', error);
    res.status(500).json({
      error: 'Failed to generate quote',
      message: error instanceof Error ? error.message : String(error)
    });
  }
}

// ============================================================================
// Edge Runtime Handler
// ============================================================================

/**
 * Edge Runtime handler for quote generation
 * Note: Requires WASM to be fetched from a URL
 */
export async function generateQuoteEdgeHandler(request: Request): Promise<Response> {
  try {
    const body = await request.json();
    const quoteData = body as QuoteData;

    if (!quoteData.customer?.name || !quoteData.quoteRef) {
      return new Response(
        JSON.stringify({ error: 'Missing required fields' }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      );
    }

    // Load WASM from URL (Edge can't read filesystem)
    const { loadZigPdf } = await import('../zigpdf-loader');
    const zigPdf = await loadZigPdf({ wasmUrl: '/zigpdf.wasm' });

    // Generate PDF
    const pdfBytes = generateQuotePdf(zigPdf, quoteData);

    return new Response(pdfBytes, {
      status: 200,
      headers: {
        'Content-Type': 'application/pdf',
        'Content-Disposition': `attachment; filename="${quoteData.quoteRef}.pdf"`
      }
    });
  } catch (error) {
    console.error('Quote generation error:', error);
    return new Response(
      JSON.stringify({ error: 'Failed to generate quote' }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    );
  }
}

// Export config for Edge runtime
export const config = {
  runtime: 'edge' // Uncomment to use Edge runtime
};
