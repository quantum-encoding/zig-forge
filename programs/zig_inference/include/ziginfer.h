/* ziginfer.h — C API for the Zig inference engine.
 *
 * Embedding usage (load the model once, reuse the handle for many calls):
 *
 *     void *m = ziginfer_create("Qwen3-Embedding-4B-Q8_0.gguf");
 *     float vec[2560];
 *     int dim = ziginfer_embed(m, "What is the capital of China?", 1, NULL,
 *                              vec, 2560);   // is_query=1 -> instruction-wrapped
 *     // ... cosine(vec_query, vec_doc) for retrieval ...
 *     ziginfer_destroy(m);
 *
 * The handle is NOT thread-safe: serialize calls, or create one handle per thread
 * (each mmaps the same file; the OS shares the pages).
 */
#ifndef ZIGINFER_H
#define ZIGINFER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Load a model from a GGUF path. Returns an opaque handle, or NULL on failure.
 * Thread count is auto-detected. Call ziginfer_destroy() to free. */
void *ziginfer_create(const char *model_path);

/* Free a model handle. */
void ziginfer_destroy(void *model);

/* Embed `text` into a normalized vector written to `out` (capacity in floats).
 *
 *   is_query != 0 : wrap as "Instruct: {task}\nQuery:{text}" (Qwen3-Embedding query
 *                   form). Pass task=NULL or "" for the default retrieval instruction.
 *   is_query == 0 : embed `text` verbatim (document form).
 *
 * out_capacity below the model's embedding dim truncates then re-normalizes (Matryoshka).
 * Returns the number of dims written, or a negative value on error.
 * Qwen3-Embedding dims: 0.6B=1024, 4B=2560, 8B=4096. */
int ziginfer_embed(void *model, const char *text, int is_query,
                   const char *task, float *out, size_t out_capacity);

/* Text generation (existing API): writes generated text into output_buf, returns
 * bytes written or negative on error. */
int ziginfer_generate(void *model, const char *prompt, unsigned int max_tokens,
                      float temperature, char *output_buf, size_t output_buf_len);

#ifdef __cplusplus
}
#endif

#endif /* ZIGINFER_H */
