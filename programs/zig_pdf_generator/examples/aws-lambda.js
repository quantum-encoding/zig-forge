/**
 * AWS Lambda - PDF Generation via Zig WASM
 *
 * Deploy PDF generation to AWS Lambda with API Gateway or EventBridge triggers.
 * Works with Lambda Node.js 18+ runtime.
 *
 * Setup:
 * 1. Build the WASM module: `zig build wasm`
 * 2. Create deployment package:
 *    - Include index.js (this file)
 *    - Include zigpdf.wasm
 *    - Include node_modules (aws-sdk is provided by Lambda)
 * 3. Deploy with SAM, CDK, or Serverless Framework
 *
 * SAM template.yaml example:
 * ```yaml
 * AWSTemplateFormatVersion: '2010-09-09'
 * Transform: AWS::Serverless-2016-10-31
 *
 * Resources:
 *   PdfGeneratorFunction:
 *     Type: AWS::Serverless::Function
 *     Properties:
 *       Handler: index.handler
 *       Runtime: nodejs18.x
 *       MemorySize: 512
 *       Timeout: 30
 *       Environment:
 *         Variables:
 *           S3_BUCKET: !Ref PdfBucket
 *       Policies:
 *         - S3CrudPolicy:
 *             BucketName: !Ref PdfBucket
 *       Events:
 *         Api:
 *           Type: Api
 *           Properties:
 *             Path: /generate/{type}
 *             Method: POST
 *
 *   PdfBucket:
 *     Type: AWS::S3::Bucket
 * ```
 */

const { S3Client, PutObjectCommand, GetObjectCommand } = require('@aws-sdk/client-s3');
const { getSignedUrl } = require('@aws-sdk/s3-request-presigner');
const { readFileSync } = require('fs');
const path = require('path');
const crypto = require('crypto');

const s3 = new S3Client({});

// =============================================================================
// WASM Module
// =============================================================================

let wasmExports = null;

async function initWasm() {
  if (wasmExports) return wasmExports;

  // Lambda packages WASM file alongside the handler
  const wasmPath = path.join(__dirname, 'zigpdf.wasm');
  const wasmBuffer = readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);

  const instance = await WebAssembly.instantiate(wasmModule, {
    wasi_snapshot_preview1: {
      fd_write: () => 0,
      fd_close: () => 0,
      fd_seek: () => 0,
      fd_read: () => 0,
      proc_exit: (code) => { throw new Error(`Exit: ${code}`); },
      environ_sizes_get: (countPtr, sizePtr) => {
        const view = new DataView(instance.exports.memory.buffer);
        view.setUint32(countPtr, 0, true);
        view.setUint32(sizePtr, 0, true);
        return 0;
      },
      environ_get: () => 0,
      args_sizes_get: (argcPtr, argvBufSizePtr) => {
        const view = new DataView(instance.exports.memory.buffer);
        view.setUint32(argcPtr, 0, true);
        view.setUint32(argvBufSizePtr, 0, true);
        return 0;
      },
      args_get: () => 0,
      clock_time_get: (clockId, precision, timePtr) => {
        const view = new DataView(instance.exports.memory.buffer);
        view.setBigUint64(timePtr, BigInt(Date.now()) * 1000000n, true);
        return 0;
      },
      random_get: (bufPtr, bufLen) => {
        const buffer = new Uint8Array(instance.exports.memory.buffer, bufPtr, bufLen);
        crypto.randomFillSync(buffer);
        return 0;
      },
    },
  });

  wasmExports = instance.exports;
  return wasmExports;
}

function generatePdf(exports, functionName, data) {
  const { memory, wasm_alloc, wasm_free } = exports;
  const generateFn = exports[functionName];

  if (!generateFn) throw new Error(`Unknown function: ${functionName}`);

  const encoder = new TextEncoder();
  const jsonStr = JSON.stringify(data);
  const jsonBytes = encoder.encode(jsonStr);

  const inputPtr = wasm_alloc(jsonBytes.length + 1);
  if (inputPtr === 0) throw new Error('Allocation failed');

  new Uint8Array(memory.buffer, inputPtr, jsonBytes.length + 1).set(jsonBytes);
  new Uint8Array(memory.buffer)[inputPtr + jsonBytes.length] = 0;

  const lenPtr = wasm_alloc(4);
  if (lenPtr === 0) {
    wasm_free(inputPtr, jsonBytes.length + 1);
    throw new Error('Allocation failed');
  }

  const pdfPtr = generateFn(inputPtr, lenPtr);
  wasm_free(inputPtr, jsonBytes.length + 1);

  if (pdfPtr === 0) {
    wasm_free(lenPtr, 4);
    const errorPtr = exports.zigpdf_get_error();
    const errorView = new Uint8Array(memory.buffer, errorPtr, 256);
    throw new Error(new TextDecoder().decode(errorView.subarray(0, errorView.indexOf(0))));
  }

  const pdfLen = new DataView(memory.buffer).getUint32(lenPtr, true);
  wasm_free(lenPtr, 4);

  const pdfBytes = new Uint8Array(memory.buffer, pdfPtr, pdfLen).slice();
  wasm_free(pdfPtr, pdfLen);

  return pdfBytes;
}

// =============================================================================
// PDF Type Mapping
// =============================================================================

const FUNCTION_MAP = {
  'invoice': 'zigpdf_generate_invoice',
  'dividend-voucher': 'zigpdf_generate_dividend_voucher',
  'dividend_voucher': 'zigpdf_generate_dividend_voucher',
  'share-certificate': 'zigpdf_generate_share_certificate',
  'share_certificate': 'zigpdf_generate_share_certificate',
  'contract': 'zigpdf_generate_contract',
  'board-resolution': 'zigpdf_generate_board_resolution',
  'board_resolution': 'zigpdf_generate_board_resolution',
  'stock-transfer': 'zigpdf_generate_stock_transfer',
  'stock_transfer': 'zigpdf_generate_stock_transfer',
  'director-consent': 'zigpdf_generate_director_consent',
  'director_consent': 'zigpdf_generate_director_consent',
  'director-appointment': 'zigpdf_generate_director_appointment',
  'director_appointment': 'zigpdf_generate_director_appointment',
  'director-resignation': 'zigpdf_generate_director_resignation',
  'director_resignation': 'zigpdf_generate_director_resignation',
  'written-resolution': 'zigpdf_generate_written_resolution',
  'written_resolution': 'zigpdf_generate_written_resolution',
};

// =============================================================================
// Lambda Handler - API Gateway
// =============================================================================

/**
 * Main Lambda handler for API Gateway
 * Routes: POST /generate/{type}, GET /health
 */
exports.handler = async (event, context) => {
  // Keep Lambda warm by reusing WASM instance
  context.callbackWaitsForEmptyEventLoop = false;

  const headers = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  };

  // CORS preflight
  if (event.httpMethod === 'OPTIONS') {
    return { statusCode: 204, headers, body: '' };
  }

  const path = event.path || event.rawPath || '';

  // Health check
  if (path === '/health' || path === '/') {
    try {
      const exports = await initWasm();
      const versionPtr = exports.zigpdf_version();
      const versionView = new Uint8Array(exports.memory.buffer, versionPtr, 20);
      const version = new TextDecoder().decode(versionView.subarray(0, versionView.indexOf(0)));

      return {
        statusCode: 200,
        headers: { ...headers, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          status: 'ok',
          version,
          memory_pages: exports.wasm_memory_size(),
          platform: 'AWS Lambda',
          types: Object.keys(FUNCTION_MAP).filter(k => !k.includes('_')),
        }),
      };
    } catch (e) {
      return {
        statusCode: 500,
        headers: { ...headers, 'Content-Type': 'application/json' },
        body: JSON.stringify({ status: 'error', error: e.message }),
      };
    }
  }

  // Generate PDF: POST /generate/{type}
  if (event.httpMethod === 'POST' && path.startsWith('/generate/')) {
    const type = event.pathParameters?.type || path.split('/')[2];
    const functionName = FUNCTION_MAP[type];

    if (!functionName) {
      return {
        statusCode: 400,
        headers: { ...headers, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          error: `Unknown PDF type: ${type}`,
          available: Object.keys(FUNCTION_MAP).filter(k => !k.includes('_')),
        }),
      };
    }

    try {
      const body = event.isBase64Encoded
        ? JSON.parse(Buffer.from(event.body, 'base64').toString())
        : JSON.parse(event.body);

      const exports = await initWasm();
      const pdfBytes = generatePdf(exports, functionName, body);

      // Check if caller wants S3 storage
      const queryParams = event.queryStringParameters || {};
      if (queryParams.store === 'true') {
        const bucket = queryParams.bucket || process.env.S3_BUCKET;
        const key = `${type}/${Date.now()}-${crypto.randomBytes(4).toString('hex')}.pdf`;

        await s3.send(new PutObjectCommand({
          Bucket: bucket,
          Key: key,
          Body: Buffer.from(pdfBytes),
          ContentType: 'application/pdf',
        }));

        const signedUrl = await getSignedUrl(s3, new GetObjectCommand({
          Bucket: bucket,
          Key: key,
        }), { expiresIn: 86400 }); // 24 hours

        return {
          statusCode: 200,
          headers: { ...headers, 'Content-Type': 'application/json' },
          body: JSON.stringify({
            success: true,
            type,
            size: pdfBytes.length,
            s3Key: key,
            downloadUrl: signedUrl,
          }),
        };
      }

      // Return PDF directly (base64 for API Gateway binary)
      return {
        statusCode: 200,
        headers: {
          ...headers,
          'Content-Type': 'application/pdf',
          'Content-Disposition': `attachment; filename="${type}.pdf"`,
        },
        body: Buffer.from(pdfBytes).toString('base64'),
        isBase64Encoded: true,
      };
    } catch (e) {
      console.error('PDF generation error:', e);
      return {
        statusCode: 500,
        headers: { ...headers, 'Content-Type': 'application/json' },
        body: JSON.stringify({ error: e.message }),
      };
    }
  }

  return {
    statusCode: 404,
    headers: { ...headers, 'Content-Type': 'application/json' },
    body: JSON.stringify({ error: 'Not Found' }),
  };
};

// =============================================================================
// Lambda Handler - SQS Trigger (Async Processing)
// =============================================================================

/**
 * SQS-triggered handler for async PDF generation
 * Message format: { type: "invoice", data: {...}, s3Bucket: "...", s3Key: "..." }
 */
exports.sqsHandler = async (event) => {
  const exports = await initWasm();
  const results = [];

  for (const record of event.Records) {
    const message = JSON.parse(record.body);
    const { type, data, s3Bucket, s3Key, callbackUrl } = message;

    try {
      const functionName = FUNCTION_MAP[type];
      if (!functionName) throw new Error(`Unknown type: ${type}`);

      const pdfBytes = generatePdf(exports, functionName, data);

      // Upload to S3
      const bucket = s3Bucket || process.env.S3_BUCKET;
      const key = s3Key || `${type}/${Date.now()}.pdf`;

      await s3.send(new PutObjectCommand({
        Bucket: bucket,
        Key: key,
        Body: Buffer.from(pdfBytes),
        ContentType: 'application/pdf',
      }));

      const signedUrl = await getSignedUrl(s3, new GetObjectCommand({
        Bucket: bucket,
        Key: key,
      }), { expiresIn: 604800 }); // 7 days

      console.log(`Generated ${type} PDF: s3://${bucket}/${key}`);

      // Callback if provided
      if (callbackUrl) {
        await fetch(callbackUrl, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ success: true, type, s3Key: key, downloadUrl: signedUrl }),
        });
      }

      results.push({ messageId: record.messageId, success: true, s3Key: key });
    } catch (e) {
      console.error(`Error processing ${record.messageId}:`, e);
      results.push({ messageId: record.messageId, success: false, error: e.message });

      if (callbackUrl) {
        await fetch(callbackUrl, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ success: false, error: e.message }),
        });
      }
    }
  }

  return { batchItemFailures: results.filter(r => !r.success).map(r => ({ itemIdentifier: r.messageId })) };
};

// =============================================================================
// Lambda Handler - EventBridge (Scheduled/Event-Driven)
// =============================================================================

/**
 * EventBridge-triggered handler
 * Use for scheduled reports or event-driven generation
 */
exports.eventBridgeHandler = async (event) => {
  const { type, data, outputBucket, outputKey } = event.detail;

  const exports = await initWasm();
  const functionName = FUNCTION_MAP[type];

  if (!functionName) {
    throw new Error(`Unknown PDF type: ${type}`);
  }

  const pdfBytes = generatePdf(exports, functionName, data);

  const bucket = outputBucket || process.env.S3_BUCKET;
  const key = outputKey || `${type}/${new Date().toISOString().split('T')[0]}/${Date.now()}.pdf`;

  await s3.send(new PutObjectCommand({
    Bucket: bucket,
    Key: key,
    Body: Buffer.from(pdfBytes),
    ContentType: 'application/pdf',
  }));

  return {
    success: true,
    type,
    s3Uri: `s3://${bucket}/${key}`,
    size: pdfBytes.length,
  };
};

// =============================================================================
// Lambda Handler - S3 Trigger (Process Uploaded JSON)
// =============================================================================

/**
 * S3-triggered handler: converts uploaded JSON to PDF
 * Trigger on: s3:ObjectCreated:* in /pdf-requests/ prefix
 * Output: same bucket, /pdf-output/ prefix
 */
exports.s3Handler = async (event) => {
  const exports = await initWasm();

  for (const record of event.Records) {
    const bucket = record.s3.bucket.name;
    const key = decodeURIComponent(record.s3.object.key.replace(/\+/g, ' '));

    if (!key.startsWith('pdf-requests/') || !key.endsWith('.json')) {
      continue;
    }

    try {
      // Download JSON
      const response = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
      const jsonContent = await response.Body.transformToString();
      const { type, data } = JSON.parse(jsonContent);

      const functionName = FUNCTION_MAP[type];
      if (!functionName) {
        console.error(`Unknown type in ${key}: ${type}`);
        continue;
      }

      // Generate PDF
      const pdfBytes = generatePdf(exports, functionName, data);

      // Save PDF
      const outputKey = key.replace('pdf-requests/', 'pdf-output/').replace('.json', '.pdf');
      await s3.send(new PutObjectCommand({
        Bucket: bucket,
        Key: outputKey,
        Body: Buffer.from(pdfBytes),
        ContentType: 'application/pdf',
      }));

      console.log(`Converted ${key} -> ${outputKey}`);
    } catch (e) {
      console.error(`Error processing ${key}:`, e);
    }
  }
};

/*
Deployment with SAM CLI:

sam init
sam build
sam deploy --guided

Example curl commands:

# Generate PDF directly
curl -X POST https://xxx.execute-api.region.amazonaws.com/Prod/generate/invoice \
  -H "Content-Type: application/json" \
  -d '{"invoice_number":"INV-001",...}' \
  -o invoice.pdf

# Generate and store in S3
curl -X POST "https://xxx.execute-api.region.amazonaws.com/Prod/generate/invoice?store=true" \
  -H "Content-Type: application/json" \
  -d '{"invoice_number":"INV-001",...}'

Response: { "success": true, "s3Key": "invoice/123.pdf", "downloadUrl": "https://..." }
*/
