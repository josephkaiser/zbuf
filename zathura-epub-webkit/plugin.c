/* zathura-epub-webkit: a zathura plugin that opens EPUBs through WebKit, so
 * MathML equations, SVG and modern CSS look the way they do in Apple Books or
 * on a Kindle (MuPDF prints MathML as a flat run of symbols).
 *
 * The work happens in epub-webkit-helper (helper.swift), one per open book,
 * which lays the book out into fixed-size pages and draws them on request.
 * This file only talks to it over a pipe; see helper.swift for the protocol.
 * The helper is looked for next to this library.
 */

#include <cairo.h>
#include <dlfcn.h>
#include <errno.h>
#include <glib.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include <girara/datastructures.h>
#include <girara/log.h>
#include <zathura/plugin-api.h>

typedef struct {
  GPid pid;
  FILE* to;   /* helper's stdin */
  FILE* from; /* helper's stdout */
  GMutex lock;
  unsigned int pages;
  double width, height;
  char** labels; /* print page per page ("41", "41–42"), NULL-terminated; "" for none */
} book_t;

/* directory this library was loaded from */
static char* here(void) {
  Dl_info info;
  if (dladdr((void*)here, &info) == 0 || info.dli_fname == NULL) {
    return NULL;
  }
  return g_path_get_dirname(info.dli_fname);
}

static void book_close(book_t* b) {
  if (b == NULL) {
    return;
  }
  if (b->to != NULL) {
    fclose(b->to); /* EOF on stdin ends the helper */
  }
  if (b->from != NULL) {
    fclose(b->from);
  }
  if (b->pid > 0) {
    /* give it a moment to exit on its own, then make sure */
    for (int i = 0; i < 20 && waitpid(b->pid, NULL, WNOHANG) == 0; i++) {
      g_usleep(10000);
    }
    if (waitpid(b->pid, NULL, WNOHANG) == 0) {
      kill(b->pid, SIGKILL);
      waitpid(b->pid, NULL, 0);
    }
  }
  g_strfreev(b->labels);
  g_mutex_clear(&b->lock);
  g_free(b);
}

/* one reply line from the helper, without its newline; NULL if it went away */
static char* read_line(book_t* b) {
  char* line = NULL;
  size_t cap = 0;
  ssize_t n  = getline(&line, &cap, b->from);
  if (n <= 0) {
    free(line);
    return NULL;
  }
  if (line[n - 1] == '\n') {
    line[n - 1] = '\0';
  }
  return line;
}

static zathura_error_t document_open(zathura_document_t* document) {
  const char* path = zathura_document_get_path(document);
  g_autofree char* dir    = here();
  g_autofree char* helper = dir != NULL ? g_build_filename(dir, "epub-webkit-helper", NULL) : NULL;
  if (path == NULL || helper == NULL || !g_file_test(helper, G_FILE_TEST_IS_EXECUTABLE)) {
    girara_error("epub-webkit: helper not found next to the plugin");
    return ZATHURA_ERROR_UNKNOWN;
  }

  book_t* b = g_new0(book_t, 1);
  g_mutex_init(&b->lock);
  char* argv[] = {helper, (char*)path, NULL};
  int in = -1, out = -1;
  GError* err = NULL;
  if (!g_spawn_async_with_pipes(NULL, argv, NULL, G_SPAWN_DO_NOT_REAP_CHILD, NULL, NULL, &b->pid, &in, &out, NULL,
                                &err)) {
    girara_error("epub-webkit: could not start the helper: %s", err->message);
    g_error_free(err);
    book_close(b);
    return ZATHURA_ERROR_UNKNOWN;
  }
  b->to   = fdopen(in, "w");
  b->from = fdopen(out, "r");

  /* "ok PAGES WIDTH HEIGHT MODE" once the book is laid out */
  char* line = read_line(b);
  unsigned int pages = 0, w = 0, h = 0;
  char mode[16] = "";
  if (line == NULL || sscanf(line, "ok %u %u %u %15s", &pages, &w, &h, mode) < 3 || pages == 0) {
    girara_error("epub-webkit: %s", line != NULL ? line : "the helper quit");
    free(line);
    book_close(b);
    return ZATHURA_ERROR_UNKNOWN;
  }
  free(line);
  /* scroll: the pages are strips of one long column, meant to be shown with no gap
   * between them; zbuf (zbuf-index.c) reads this and sets zathura's page-v-padding */
  g_setenv("ZATHURA_EPUB_WEBKIT_MODE", mode, TRUE);
  b->pages  = pages;
  b->width  = w;
  b->height = h;

  /* print page numbers, for books that mark them */
  fprintf(b->to, "labels\n");
  fflush(b->to);
  line = read_line(b);
  unsigned int count = 0;
  if (line != NULL && sscanf(line, "labels %u", &count) == 1 && count == pages) {
    b->labels = g_new0(char*, count + 1);
    for (unsigned int i = 0; i < count; i++) {
      char* label = read_line(b);
      b->labels[i] = g_strdup(label != NULL ? label : "");
      free(label);
    }
  }
  free(line);

  zathura_document_set_number_of_pages(document, pages);
  zathura_document_set_data(document, b);
  return ZATHURA_ERROR_OK;
}

static zathura_error_t document_free(zathura_document_t* UNUSED(document), void* data) {
  book_close(data);
  return ZATHURA_ERROR_OK;
}

static zathura_error_t page_init(zathura_page_t* page) {
  book_t* b = zathura_document_get_data(zathura_page_get_document(page));
  if (b == NULL) {
    return ZATHURA_ERROR_UNKNOWN;
  }
  zathura_page_set_width(page, b->width);
  zathura_page_set_height(page, b->height);
  return ZATHURA_ERROR_OK;
}

/* zathura shows it in the statusbar as [41 (318/1114)] and in the contents (Tab);
 * no label is not an error, which would make zathura drop the page */
static zathura_error_t page_get_label(zathura_page_t* page, void* UNUSED(data), char** label) {
  book_t* b = zathura_document_get_data(zathura_page_get_document(page));
  unsigned int index = zathura_page_get_index(page);
  *label = NULL;
  if (b != NULL && b->labels != NULL && index < b->pages && b->labels[index][0] != '\0') {
    *label = g_strdup(b->labels[index]);
  }
  return ZATHURA_ERROR_OK;
}

static zathura_error_t page_clear(zathura_page_t* UNUSED(page), void* UNUSED(data)) {
  return ZATHURA_ERROR_OK;
}

/* page `index` from the helper into an image surface of any size */
static zathura_error_t draw(book_t* b, unsigned int index, cairo_surface_t* surface) {
  int w = cairo_image_surface_get_width(surface), h = cairo_image_surface_get_height(surface);
  int stride = cairo_image_surface_get_stride(surface);
  if (w <= 0 || h <= 0) {
    return ZATHURA_ERROR_OK;
  }
  cairo_surface_flush(surface);
  unsigned char* pixels = cairo_image_surface_get_data(surface);

  zathura_error_t result = ZATHURA_ERROR_UNKNOWN;
  g_mutex_lock(&b->lock);
  fprintf(b->to, "render %u %d %d\n", index, w, h);
  fflush(b->to);
  char* line = read_line(b);
  int rw = 0, rh = 0;
  if (line != NULL && sscanf(line, "img %d %d", &rw, &rh) == 2 && rw == w && rh == h) {
    /* rows arrive packed; the surface may pad them */
    bool ok = true;
    for (int y = 0; y < h && ok; y++) {
      ok = fread(pixels + (size_t)y * stride, 4, w, b->from) == (size_t)w;
    }
    result = ok ? ZATHURA_ERROR_OK : ZATHURA_ERROR_UNKNOWN;
  } else {
    girara_error("epub-webkit: page %u: %s", index + 1, line != NULL ? line : "the helper quit");
  }
  free(line);
  g_mutex_unlock(&b->lock);
  cairo_surface_mark_dirty(surface);
  return result;
}

static zathura_error_t page_render_cairo(zathura_page_t* page, void* UNUSED(data), cairo_t* cairo,
                                         bool UNUSED(printing)) {
  book_t* b = zathura_document_get_data(zathura_page_get_document(page));
  if (b == NULL) {
    return ZATHURA_ERROR_UNKNOWN;
  }
  unsigned int index      = zathura_page_get_index(page);
  cairo_surface_t* target = cairo_get_target(cairo);

  /* the usual case: zathura hands us a fresh image surface the size of the page on screen */
  if (cairo_surface_get_type(target) == CAIRO_SURFACE_TYPE_IMAGE) {
    return draw(b, index, target);
  }

  /* printing and the like: draw at 2x into our own surface, then paint that in page units */
  int w = (int)(b->width * 2), h = (int)(b->height * 2);
  cairo_surface_t* img = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
  zathura_error_t err  = draw(b, index, img);
  if (err == ZATHURA_ERROR_OK) {
    cairo_save(cairo);
    cairo_scale(cairo, 0.5, 0.5);
    cairo_set_source_surface(cairo, img, 0, 0);
    cairo_paint(cairo);
    cairo_restore(cairo);
  }
  cairo_surface_destroy(img);
  return err;
}

static girara_tree_node_t* index_generate(zathura_document_t* UNUSED(document), void* data, zathura_error_t* error) {
  book_t* b = data;
  g_mutex_lock(&b->lock);
  fprintf(b->to, "toc\n");
  fflush(b->to);
  char* line = read_line(b);
  unsigned int count = 0;
  if (line == NULL || sscanf(line, "toc %u", &count) != 1) {
    free(line);
    g_mutex_unlock(&b->lock);
    if (error != NULL) {
      *error = ZATHURA_ERROR_UNKNOWN;
    }
    return NULL;
  }
  free(line);

  /* no free function, as in zathura-pdf-mupdf: zathura's index view keeps using the
   * entries after the document closes, and freeing them there crashes the next Tab */
  girara_tree_node_t* root = girara_node_new(zathura_index_element_new("ROOT"));
  /* parents[l] is the latest entry at level l; deeper entries hang under it */
  GPtrArray* parents = g_ptr_array_new();
  g_ptr_array_add(parents, root);

  for (unsigned int i = 0; i < count; i++) {
    char* entry = read_line(b);
    if (entry == NULL) {
      break;
    }
    unsigned int level = 0, page = 0;
    int title_at       = 0;
    if (sscanf(entry, "%u %u %n", &level, &page, &title_at) >= 2 && title_at > 0) {
      zathura_index_element_t* el = zathura_index_element_new(entry + title_at);
      zathura_rectangle_t rect    = {0, 0, 0, 0};
      zathura_link_target_t target = {ZATHURA_LINK_DESTINATION_XYZ, NULL, page, -1, -1, -1, -1, 0};
      el->link = zathura_link_new(ZATHURA_LINK_GOTO_DEST, rect, target);
      /* a level can only go one deeper than the one above it */
      if (level + 1 > parents->len) {
        level = parents->len - 1;
      }
      girara_tree_node_t* node = girara_node_append_data(g_ptr_array_index(parents, level), el);
      g_ptr_array_set_size(parents, level + 1);
      g_ptr_array_add(parents, node);
    }
    free(entry);
  }
  g_ptr_array_free(parents, TRUE);
  g_mutex_unlock(&b->lock);
  return root;
}

ZATHURA_PLUGIN_REGISTER_WITH_FUNCTIONS("epub-webkit", 0, 1, 0,
                                       ZATHURA_PLUGIN_FUNCTIONS({
                                           .document_open     = document_open,
                                           .document_free     = document_free,
                                           .document_index_generate = index_generate,
                                           .page_init         = page_init,
                                           .page_clear        = page_clear,
                                           .page_get_label    = page_get_label,
                                           .page_render_cairo = page_render_cairo,
                                       }),
                                       ZATHURA_PLUGIN_MIMETYPES({"application/epub+zip"}))
