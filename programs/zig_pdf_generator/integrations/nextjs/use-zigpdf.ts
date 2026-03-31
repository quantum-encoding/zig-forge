'use client';

/**
 * React Hook for ZigPDF
 *
 * Provides easy access to the ZigPDF WASM module in React components.
 */

import { useState, useEffect, useCallback, useRef } from 'react';
import { loadZigPdf, isLoaded, getModule, unload, type LoadOptions } from './zigpdf-loader';
import { generateQuotePdf, downloadQuotePdf, openQuotePdf, generateQuoteTemplate } from './quote-generator';
import type { ZigPdfModule, QuoteData, PresentationTemplate } from './types';

// ============================================================================
// Hook State Types
// ============================================================================

export interface UseZigPdfState {
  /** Whether the WASM module is loaded */
  isLoaded: boolean;
  /** Whether the module is currently loading */
  isLoading: boolean;
  /** Any error that occurred during loading */
  error: Error | null;
  /** The loaded module (null if not loaded) */
  module: ZigPdfModule | null;
}

export interface UseZigPdfActions {
  /** Manually trigger loading (called automatically on mount) */
  load: () => Promise<void>;
  /** Unload the module and free resources */
  reset: () => void;
  /** Generate PDF bytes from a quote */
  generateQuote: (data: QuoteData) => Uint8Array | null;
  /** Generate and download a quote PDF */
  downloadQuote: (data: QuoteData, filename?: string) => void;
  /** Generate and open a quote PDF in new tab */
  openQuote: (data: QuoteData) => void;
  /** Get the JSON template without generating PDF */
  getTemplate: (data: QuoteData) => PresentationTemplate;
  /** Generate PDF from raw JSON template */
  generateFromTemplate: (template: PresentationTemplate) => Uint8Array | null;
}

export type UseZigPdfReturn = UseZigPdfState & UseZigPdfActions;

// ============================================================================
// Main Hook
// ============================================================================

/**
 * React hook for using ZigPDF in components
 *
 * @example
 * ```tsx
 * function QuoteGenerator() {
 *   const { isLoaded, isLoading, error, downloadQuote } = useZigPdf();
 *
 *   if (isLoading) return <div>Loading PDF engine...</div>;
 *   if (error) return <div>Failed to load: {error.message}</div>;
 *
 *   return (
 *     <button onClick={() => downloadQuote(quoteData)}>
 *       Download Quote
 *     </button>
 *   );
 * }
 * ```
 */
export function useZigPdf(options: LoadOptions = {}): UseZigPdfReturn {
  const [state, setState] = useState<UseZigPdfState>({
    isLoaded: isLoaded(),
    isLoading: false,
    error: null,
    module: isLoaded() ? getModule() : null
  });

  const loadedRef = useRef(false);

  // Load on mount
  useEffect(() => {
    if (loadedRef.current) return;
    loadedRef.current = true;

    // Skip if already loaded
    if (isLoaded()) {
      setState({
        isLoaded: true,
        isLoading: false,
        error: null,
        module: getModule()
      });
      return;
    }

    // Start loading
    setState(s => ({ ...s, isLoading: true }));

    loadZigPdf(options)
      .then(module => {
        setState({
          isLoaded: true,
          isLoading: false,
          error: null,
          module
        });
      })
      .catch(error => {
        setState({
          isLoaded: false,
          isLoading: false,
          error: error instanceof Error ? error : new Error(String(error)),
          module: null
        });
      });
  }, [options.wasmUrl, options.forceReload]);

  // Manual load function
  const load = useCallback(async () => {
    setState(s => ({ ...s, isLoading: true, error: null }));

    try {
      const module = await loadZigPdf({ ...options, forceReload: true });
      setState({
        isLoaded: true,
        isLoading: false,
        error: null,
        module
      });
    } catch (error) {
      setState({
        isLoaded: false,
        isLoading: false,
        error: error instanceof Error ? error : new Error(String(error)),
        module: null
      });
    }
  }, [options]);

  // Reset function
  const reset = useCallback(() => {
    unload();
    loadedRef.current = false;
    setState({
      isLoaded: false,
      isLoading: false,
      error: null,
      module: null
    });
  }, []);

  // Generate quote PDF
  const generateQuote = useCallback((data: QuoteData): Uint8Array | null => {
    if (!state.module) {
      console.error('ZigPDF module not loaded');
      return null;
    }
    try {
      return generateQuotePdf(state.module, data);
    } catch (error) {
      console.error('Failed to generate quote:', error);
      return null;
    }
  }, [state.module]);

  // Download quote PDF
  const downloadQuote = useCallback((data: QuoteData, filename?: string) => {
    if (!state.module) {
      console.error('ZigPDF module not loaded');
      return;
    }
    try {
      downloadQuotePdf(state.module, data, filename);
    } catch (error) {
      console.error('Failed to download quote:', error);
    }
  }, [state.module]);

  // Open quote PDF in new tab
  const openQuote = useCallback((data: QuoteData) => {
    if (!state.module) {
      console.error('ZigPDF module not loaded');
      return;
    }
    try {
      openQuotePdf(state.module, data);
    } catch (error) {
      console.error('Failed to open quote:', error);
    }
  }, [state.module]);

  // Get template without generating PDF
  const getTemplate = useCallback((data: QuoteData): PresentationTemplate => {
    return generateQuoteTemplate(data);
  }, []);

  // Generate from raw template
  const generateFromTemplate = useCallback((template: PresentationTemplate): Uint8Array | null => {
    if (!state.module) {
      console.error('ZigPDF module not loaded');
      return null;
    }
    try {
      return state.module.generatePresentation(JSON.stringify(template));
    } catch (error) {
      console.error('Failed to generate PDF:', error);
      return null;
    }
  }, [state.module]);

  return {
    ...state,
    load,
    reset,
    generateQuote,
    downloadQuote,
    openQuote,
    getTemplate,
    generateFromTemplate
  };
}

// ============================================================================
// Context Provider (Optional)
// ============================================================================

import { createContext, useContext, type ReactNode } from 'react';

const ZigPdfContext = createContext<UseZigPdfReturn | null>(null);

export interface ZigPdfProviderProps {
  children: ReactNode;
  wasmUrl?: string;
}

/**
 * Provider component for sharing ZigPDF instance across components
 *
 * @example
 * ```tsx
 * // In layout.tsx or _app.tsx
 * export default function RootLayout({ children }) {
 *   return (
 *     <ZigPdfProvider wasmUrl="/zigpdf.wasm">
 *       {children}
 *     </ZigPdfProvider>
 *   );
 * }
 *
 * // In any component
 * function MyComponent() {
 *   const { downloadQuote } = useZigPdfContext();
 *   // ...
 * }
 * ```
 */
export function ZigPdfProvider({ children, wasmUrl }: ZigPdfProviderProps) {
  const zigPdf = useZigPdf({ wasmUrl });

  return (
    <ZigPdfContext.Provider value={zigPdf}>
      {children}
    </ZigPdfContext.Provider>
  );
}

/**
 * Use the ZigPDF context (must be inside ZigPdfProvider)
 */
export function useZigPdfContext(): UseZigPdfReturn {
  const context = useContext(ZigPdfContext);
  if (!context) {
    throw new Error('useZigPdfContext must be used within a ZigPdfProvider');
  }
  return context;
}
