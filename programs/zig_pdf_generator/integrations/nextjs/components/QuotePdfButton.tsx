'use client';

/**
 * Quote PDF Download Button Component
 *
 * A ready-to-use button component for generating and downloading quote PDFs.
 */

import { useState } from 'react';
import { useZigPdf } from '../use-zigpdf';
import type { QuoteData } from '../types';

export interface QuotePdfButtonProps {
  /** The quote data to generate */
  quoteData: QuoteData;
  /** Custom filename (default: {quoteRef}.pdf) */
  filename?: string;
  /** Button text while idle */
  label?: string;
  /** Button text while loading WASM */
  loadingLabel?: string;
  /** Button text while generating */
  generatingLabel?: string;
  /** Additional CSS classes */
  className?: string;
  /** Button variant */
  variant?: 'primary' | 'secondary' | 'outline';
  /** Whether to open in new tab instead of download */
  openInNewTab?: boolean;
  /** Callback after successful generation */
  onSuccess?: () => void;
  /** Callback on error */
  onError?: (error: Error) => void;
}

export function QuotePdfButton({
  quoteData,
  filename,
  label = 'Download Quote PDF',
  loadingLabel = 'Loading...',
  generatingLabel = 'Generating...',
  className = '',
  variant = 'primary',
  openInNewTab = false,
  onSuccess,
  onError
}: QuotePdfButtonProps) {
  const { isLoaded, isLoading, error, downloadQuote, openQuote } = useZigPdf();
  const [isGenerating, setIsGenerating] = useState(false);

  const handleClick = async () => {
    if (!isLoaded || isGenerating) return;

    setIsGenerating(true);
    try {
      if (openInNewTab) {
        openQuote(quoteData);
      } else {
        downloadQuote(quoteData, filename);
      }
      onSuccess?.();
    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err));
      onError?.(error);
    } finally {
      setIsGenerating(false);
    }
  };

  // Variant styles
  const variantStyles = {
    primary: 'bg-primary-500 hover:bg-primary-600 text-white',
    secondary: 'bg-secondary-700 hover:bg-secondary-800 text-white',
    outline: 'border-2 border-primary-500 text-primary-500 hover:bg-primary-50'
  };

  const baseStyles = `
    inline-flex items-center justify-center gap-2
    px-6 py-3 rounded-lg font-medium
    transition-colors duration-200
    disabled:opacity-50 disabled:cursor-not-allowed
  `;

  const buttonText = isLoading
    ? loadingLabel
    : isGenerating
      ? generatingLabel
      : label;

  return (
    <button
      onClick={handleClick}
      disabled={!isLoaded || isLoading || isGenerating}
      className={`${baseStyles} ${variantStyles[variant]} ${className}`}
    >
      {/* PDF Icon */}
      <svg
        className="w-5 h-5"
        fill="none"
        stroke="currentColor"
        viewBox="0 0 24 24"
      >
        <path
          strokeLinecap="round"
          strokeLinejoin="round"
          strokeWidth={2}
          d="M12 10v6m0 0l-3-3m3 3l3-3m2 8H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"
        />
      </svg>
      {buttonText}
      {(isLoading || isGenerating) && (
        <svg
          className="w-4 h-4 animate-spin"
          fill="none"
          viewBox="0 0 24 24"
        >
          <circle
            className="opacity-25"
            cx="12"
            cy="12"
            r="10"
            stroke="currentColor"
            strokeWidth="4"
          />
          <path
            className="opacity-75"
            fill="currentColor"
            d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
          />
        </svg>
      )}
    </button>
  );
}

// ============================================================================
// Inline Quote Preview Component
// ============================================================================

export interface QuotePdfPreviewProps {
  /** The quote data to preview */
  quoteData: QuoteData;
  /** Height of the preview iframe */
  height?: string | number;
  /** Additional CSS classes */
  className?: string;
}

export function QuotePdfPreview({
  quoteData,
  height = 600,
  className = ''
}: QuotePdfPreviewProps) {
  const { isLoaded, isLoading, error, module } = useZigPdf();
  const [pdfUrl, setPdfUrl] = useState<string | null>(null);
  const [previewError, setPreviewError] = useState<Error | null>(null);

  // Generate preview when module loads
  useState(() => {
    if (!isLoaded || !module) return;

    try {
      const { generateQuotePdf } = require('../quote-generator');
      const pdfBytes = generateQuotePdf(module, quoteData);
      const blob = new Blob([pdfBytes], { type: 'application/pdf' });
      const url = URL.createObjectURL(blob);
      setPdfUrl(url);

      return () => URL.revokeObjectURL(url);
    } catch (err) {
      setPreviewError(err instanceof Error ? err : new Error(String(err)));
    }
  });

  if (isLoading) {
    return (
      <div className={`flex items-center justify-center bg-gray-100 ${className}`} style={{ height }}>
        <div className="text-gray-500">Loading PDF preview...</div>
      </div>
    );
  }

  if (error || previewError) {
    return (
      <div className={`flex items-center justify-center bg-red-50 ${className}`} style={{ height }}>
        <div className="text-red-600">
          Failed to generate preview: {(error || previewError)?.message}
        </div>
      </div>
    );
  }

  if (!pdfUrl) {
    return (
      <div className={`flex items-center justify-center bg-gray-100 ${className}`} style={{ height }}>
        <div className="text-gray-500">Generating preview...</div>
      </div>
    );
  }

  return (
    <iframe
      src={pdfUrl}
      className={`w-full border-0 ${className}`}
      style={{ height }}
      title="Quote PDF Preview"
    />
  );
}
