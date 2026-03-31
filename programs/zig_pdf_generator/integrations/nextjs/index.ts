/**
 * ZigPDF Next.js Integration
 *
 * High-performance PDF generation for Next.js applications.
 *
 * @example
 * ```tsx
 * // Client-side usage
 * import { useZigPdf } from '@/lib/zigpdf';
 *
 * function QuotePage() {
 *   const { downloadQuote, isLoaded } = useZigPdf();
 *
 *   return (
 *     <button
 *       onClick={() => downloadQuote(quoteData)}
 *       disabled={!isLoaded}
 *     >
 *       Download PDF
 *     </button>
 *   );
 * }
 * ```
 */

// Types
export type {
  // Quote data types
  QuoteData,
  CustomerInfo,
  SolarSystem,
  BatterySystem,
  HeatPumpSystem,
  EVChargerSystem,
  SystemConfig,
  LineItem,
  SavingsEstimate,
  CompanyInfo,
  BrandColors,
  CompanyStats,

  // Template types
  PresentationTemplate,
  PresentationPage,
  PresentationElement,
  TextElement,
  BulletListElement,
  TableElement,
  ShapeElement,
  ImageElement,
  PageSize,

  // Module types
  ZigPdfModule,
  ZigPdfLoader
} from './types';

// WASM Loader
export {
  loadZigPdf,
  loadZigPdfServer,
  isLoaded,
  getModule,
  unload,
  type LoadOptions
} from './zigpdf-loader';

// Quote Generator
export {
  generateQuoteTemplate,
  generateQuotePdf,
  downloadQuotePdf,
  openQuotePdf,
  formatCurrency,
  calculateDeposit,
  calculateTotal,
  DEFAULT_COMPANY
} from './quote-generator';

// React Hook
export {
  useZigPdf,
  ZigPdfProvider,
  useZigPdfContext,
  type UseZigPdfState,
  type UseZigPdfActions,
  type UseZigPdfReturn,
  type ZigPdfProviderProps
} from './use-zigpdf';

// Components
export { QuotePdfButton, QuotePdfPreview } from './components/QuotePdfButton';

// API Handlers
export {
  generateQuoteHandler,
  generateQuoteGetHandler,
  generateQuoteApiHandler,
  generateQuoteEdgeHandler
} from './api/generate-quote';
