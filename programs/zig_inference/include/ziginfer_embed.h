/* ziginfer_embed.h — lean C API for local Qwen3-Embedding inference.
 *
 * Links nothing beyond libc. Load the model once, reuse the handle for many embeds:
 *
 *     void *m = ziginfer_create("Qwen3-Embedding-4B-Q8_0.gguf");
 *     int   d = ziginfer_embed_dim(m);          // 1024 / 2560 / 4096
 *     float vec[2560];
 *     int   n = ziginfer_embed(m, "What is the capital of China?", 1, NULL, vec, d);
 *     // queries: is_query=1 (instruction-wrapped). documents: is_query=0 (verbatim).
 *     // vectors are L2-normalized, so cosine similarity == dot product.
 *     ziginfer_destroy(m);
 *
 * Threading: a handle is NOT thread-safe. Serialize calls on it, or create one handle
 * per worker thread (each mmaps the same GGUF; the OS shares the physical pages).
 */
#ifndef ZIGINFER_EMBED_H
#define ZIGINFER_EMBED_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Load a GGUF model (auto-detect thread count). Returns an opaque handle or NULL. */
void *ziginfer_create(const char *model_path);

/* Load a GGUF model with an explicit thread count (0 = auto-detect). */
void *ziginfer_create_with_threads(const char *model_path, unsigned int n_threads);

/* Free a model handle. */
void ziginfer_destroy(void *model);

/* Native embedding dimension (d_model): 0.6B=1024, 4B=2560, 8B=4096. */
unsigned int ziginfer_embed_dim(void *model);

/* Embed `text` into `out` (capacity in floats). is_query!=0 applies the Qwen3-Embedding
 * query instruction wrapper ("Instruct: {task}\nQuery:{text}"); task=NULL uses the default
 * retrieval instruction. is_query==0 embeds verbatim (document). out_capacity below d_model
 * truncates then re-normalizes (Matryoshka). Returns dims written, or negative on error. */
int ziginfer_embed(void *model, const char *text, int is_query,
                   const char *task, float *out, size_t out_capacity);

#ifdef __cplusplus
}
#endif

#endif /* ZIGINFER_EMBED_H */
