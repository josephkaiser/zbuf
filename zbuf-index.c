/* zbuf-index: added to the zathura that zbuf starts, it draws two menus in
 * place of the page like the index (Tab) is:
 *
 *   b  open buffers           o  files in the current document's folder
 *
 * j/k or arrows move, Enter or l opens a file or goes into a folder, - or h
 * goes up (Enter on the folder line does too), ~ goes home, b and o swap
 * menus, q or Esc closes. A picked file is handed to zbuf, which shows it in
 * this window.
 *
 * It also shows "buffer 2/5" in the statusbar, and raises the window when a
 * file is opened, so one sent from a file manager shows up in front.
 *
 * It is not a zathura plugin. zbuf preloads it into its own zathura
 * (LD_PRELOAD, or DYLD_INSERT_LIBRARIES on macOS), and it steps in when
 * zathura looks up the definition of the plugin that opens PDFs (mupdf or
 * poppler), to learn which document is on screen. zbuf maps b and o to send
 * this process SIGUSR1 and SIGUSR2. Zathura started any other way, and its
 * plugin folder, are left alone. The document index (Tab) is the plugin's.
 */

#define _GNU_SOURCE /* RTLD_NEXT on glibc */
#include <dlfcn.h>
#include <glib-unix.h>
#include <glib.h>
#include <gmodule.h>
#include <gtk/gtk.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <zathura/plugin-api.h>

static zathura_plugin_document_open_t inner_open;
static zathura_plugin_document_free_t inner_free;
static const char* const document_types[] = {"pdf", "epub", "xps", "oxps", "cbz", "fb2", "mobi"};

enum { COL_TITLE, COL_NOTE, COL_PATH, COL_KIND, N_COLS };
enum { KIND_HEADER, KIND_DIR, KIND_FILE };
typedef enum { MENU_NONE, MENU_BUFFERS, MENU_FILES } menu_t;

static char* current_doc; /* path of the document on screen */
static char* files_dir;   /* folder the files menu is showing */
static menu_t shown;
static GtkWidget* stack;  /* girara's view, where the index is swapped in too */
static GtkWidget* previous;
static GtkWidget* menu;
static GtkTreeView* tree;
static GtkListStore* store;

static char* tilde(const char* path) {
  const char* home = g_get_home_dir();
  size_t n         = strlen(home);
  if (strncmp(path, home, n) == 0 && (path[n] == '/' || path[n] == '\0')) {
    return g_strconcat("~", path + n, NULL);
  }
  return g_strdup(path);
}

static bool is_document(const char* name) {
  const char* dot = strrchr(name, '.');
  for (size_t i = 0; dot != NULL && i < G_N_ELEMENTS(document_types); i++) {
    if (g_ascii_strcasecmp(dot + 1, document_types[i]) == 0) {
      return true;
    }
  }
  return false;
}

/* "Advanced_Bash-Scripting_Guide.pdf" -> "Advanced Bash-Scripting Guide"; the type goes in its own column */
static char* clean_name(const char* name) {
  const char* dot = strrchr(name, '.');
  char* s         = (dot != NULL && dot != name && is_document(name)) ? g_strndup(name, dot - name) : g_strdup(name);
  g_strdelimit(s, "_", ' ');
  return g_strstrip(s);
}

static char* file_type(const char* name) {
  const char* dot = strrchr(name, '.');
  return g_ascii_strdown(dot != NULL ? dot + 1 : "", -1);
}

static void add_row(const char* title_markup, const char* note, const char* path, int kind) {
  GtkTreeIter it;
  gtk_list_store_append(store, &it);
  gtk_list_store_set(store, &it, COL_TITLE, title_markup, COL_NOTE, note, COL_PATH, path, COL_KIND, kind, -1);
}

static void select_row(int row) {
  int n = gtk_tree_model_iter_n_children(GTK_TREE_MODEL(store), NULL);
  if (n == 0) {
    return;
  }
  row                = CLAMP(row, 0, n - 1);
  GtkTreePath* tpath = gtk_tree_path_new_from_indices(row, -1);
  gtk_tree_view_set_cursor(tree, tpath, NULL, FALSE);
  gtk_tree_view_scroll_to_cell(tree, tpath, NULL, FALSE, 0, 0);
  gtk_tree_path_free(tpath);
}

static int cursor_row(void) {
  GtkTreePath* tpath = NULL;
  gtk_tree_view_get_cursor(tree, &tpath, NULL);
  int row = tpath != NULL ? gtk_tree_path_get_indices(tpath)[0] : 0;
  gtk_tree_path_free(tpath);
  return row;
}

/* ---- contents ---- */

static gint by_name(gconstpointer a, gconstpointer b) {
  g_autofree char* ka = g_utf8_collate_key_for_filename(*(char* const*)a, -1);
  g_autofree char* kb = g_utf8_collate_key_for_filename(*(char* const*)b, -1);
  return strcmp(ka, kb);
}

/* the folder line first (Enter on it goes up), then folders, then documents */
static void fill_files(const char* dir, const char* select) {
  g_free(files_dir);
  files_dir = g_strdup(dir);
  gtk_list_store_clear(store);

  /* the folder's own name, with where it lives beside it */
  g_autofree char* name_of  = g_path_get_basename(dir);
  g_autofree char* parent   = g_path_get_dirname(dir);
  g_autofree char* where    = tilde(parent);
  const bool root           = g_strcmp0(dir, "/") == 0;
  const bool home           = g_strcmp0(dir, g_get_home_dir()) == 0;
  g_autofree char* header   = g_markup_printf_escaped("<b>%s/</b>", root ? "" : home ? "~" : name_of);
  g_autofree char* note     = root ? g_strdup("") : g_strdup_printf("in %s", where);
  add_row(header, note, NULL, KIND_HEADER);

  GPtrArray* dirs  = g_ptr_array_new_with_free_func(g_free);
  GPtrArray* files = g_ptr_array_new_with_free_func(g_free);
  GDir* d          = g_dir_open(dir, 0, NULL);
  const char* name;
  while (d != NULL && (name = g_dir_read_name(d)) != NULL) {
    if (name[0] == '.') {
      continue;
    }
    g_autofree char* path = g_build_filename(dir, name, NULL);
    if (g_file_test(path, G_FILE_TEST_IS_DIR)) {
      g_ptr_array_add(dirs, g_strdup(name));
    } else if (is_document(name)) {
      g_ptr_array_add(files, g_strdup(name));
    }
  }
  if (d != NULL) {
    g_dir_close(d);
  }
  g_ptr_array_sort(dirs, by_name);
  g_ptr_array_sort(files, by_name);

  int row = 1, want = 1;
  for (guint i = 0; i < dirs->len; i++, row++) {
    const char* n         = dirs->pdata[i];
    g_autofree char* path = g_build_filename(dir, n, NULL);
    g_autofree char* t    = g_markup_printf_escaped("<b>%s/</b>", n);
    add_row(t, "", path, KIND_DIR);
    if (g_strcmp0(n, select) == 0) {
      want = row;
    }
  }
  for (guint i = 0; i < files->len; i++, row++) {
    const char* n         = files->pdata[i];
    g_autofree char* path = g_build_filename(dir, n, NULL);
    const bool on         = g_strcmp0(path, current_doc) == 0;
    g_autofree char* nice = clean_name(n);
    g_autofree char* type = file_type(n);
    g_autofree char* t    = g_markup_printf_escaped("%s%s", on ? "● " : "", nice);
    add_row(t, type, path, KIND_FILE);
    if (g_strcmp0(n, select) == 0 || (select == NULL && on)) {
      want = row;
    }
  }
  if (dirs->len + files->len == 0) {
    add_row("<i>no folders or documents here</i>", "", NULL, KIND_HEADER);
  }
  g_ptr_array_free(dirs, TRUE);
  g_ptr_array_free(files, TRUE);
  select_row(want);
}

/* zbuf keeps one absolute path per line in $ZBUF_DIR/buffers */
static void fill_buffers(void) {
  gtk_list_store_clear(store);
  add_row("<b>Open buffers</b>", "", NULL, KIND_HEADER);

  g_autofree char* list = g_build_filename(g_getenv("ZBUF_DIR"), "buffers", NULL);
  g_autofree char* text = NULL;
  g_file_get_contents(list, &text, NULL, NULL);
  g_auto(GStrv) lines = g_strsplit(text != NULL ? text : "", "\n", -1);

  int row = 1, want = 1;
  for (char** l = lines; *l != NULL; l++) {
    /* zbuf forgets deleted files on its next call; until then just skip them */
    if (**l == '\0' || !g_file_test(*l, G_FILE_TEST_IS_REGULAR)) {
      continue;
    }
    g_autofree char* base  = g_path_get_basename(*l);
    g_autofree char* dir   = g_path_get_dirname(*l);
    g_autofree char* where = g_path_get_basename(dir);
    g_autofree char* nice  = clean_name(base);
    g_autofree char* type  = file_type(base);
    g_autofree char* note  = g_strdup_printf("%s  %s", where, type);
    const bool on          = g_strcmp0(*l, current_doc) == 0;
    g_autofree char* t     = g_markup_printf_escaped("%s%s", on ? "● " : "", nice);
    add_row(t, note, *l, KIND_FILE);
    if (on) {
      want = row;
    }
    row++;
  }
  if (row == 1) {
    add_row("<i>no buffers</i>", "", NULL, KIND_HEADER);
  }
  select_row(want);
}

/* ---- showing and hiding ---- */

static void close_menu(void) {
  if (shown == MENU_NONE) {
    return;
  }
  shown = MENU_NONE;
  if (previous != NULL) {
    gtk_stack_set_visible_child(GTK_STACK(stack), previous);
  }
  gtk_widget_grab_focus(stack);
}

static void up(void) {
  g_autofree char* parent = g_path_get_dirname(files_dir);
  g_autofree char* from   = g_path_get_basename(files_dir);
  if (g_strcmp0(parent, files_dir) != 0) {
    fill_files(parent, from);
  }
}

static void activate_row(void) {
  GtkTreeIter it;
  GtkTreePath* tpath = gtk_tree_path_new_from_indices(cursor_row(), -1);
  bool found         = gtk_tree_model_get_iter(GTK_TREE_MODEL(store), &it, tpath);
  gtk_tree_path_free(tpath);
  if (!found) {
    return;
  }
  g_autofree char* path = NULL;
  int kind;
  gtk_tree_model_get(GTK_TREE_MODEL(store), &it, COL_PATH, &path, COL_KIND, &kind, -1);

  if (kind == KIND_HEADER) {
    if (shown == MENU_FILES && path == NULL && cursor_row() == 0) {
      up();
    }
  } else if (kind == KIND_DIR) {
    fill_files(path, NULL);
  } else {
    close_menu();
    const char* zbuf = g_getenv("ZBUF_BIN");
    char* argv[]     = {(char*)(zbuf != NULL ? zbuf : "zbuf"), path, NULL};
    g_spawn_async(NULL, argv, NULL, G_SPAWN_SEARCH_PATH, NULL, NULL, NULL, NULL);
  }
}

static void open_menu(menu_t which);

static gboolean on_key(GtkWidget* UNUSED(w), GdkEventKey* ev, gpointer UNUSED(data)) {
  switch (ev->keyval) {
  case GDK_KEY_j:
  case GDK_KEY_Down:
    select_row(cursor_row() + 1);
    break;
  case GDK_KEY_k:
  case GDK_KEY_Up:
    select_row(cursor_row() - 1);
    break;
  case GDK_KEY_g:
    select_row(0);
    break;
  case GDK_KEY_G:
    select_row(G_MAXINT);
    break;
  case GDK_KEY_Return:
  case GDK_KEY_KP_Enter:
  case GDK_KEY_l:
  case GDK_KEY_Right:
    activate_row();
    break;
  case GDK_KEY_minus:
  case GDK_KEY_h:
  case GDK_KEY_Left:
  case GDK_KEY_BackSpace:
    if (shown == MENU_FILES) {
      up();
    }
    break;
  case GDK_KEY_asciitilde:
    if (shown == MENU_FILES) {
      fill_files(g_get_home_dir(), NULL);
    }
    break;
  case GDK_KEY_b:
    shown == MENU_BUFFERS ? close_menu() : open_menu(MENU_BUFFERS);
    break;
  case GDK_KEY_o:
    shown == MENU_FILES ? close_menu() : open_menu(MENU_FILES);
    break;
  case GDK_KEY_q:
  case GDK_KEY_Escape:
    close_menu();
    break;
  default:
    break;
  }
  return TRUE; /* nothing reaches zathura's own bindings while a menu is up */
}

static void on_row_activated(GtkTreeView* UNUSED(t), GtkTreePath* tpath, GtkTreeViewColumn* UNUSED(c), gpointer UNUSED(d)) {
  select_row(gtk_tree_path_get_indices(tpath)[0]);
  activate_row();
}

static GtkWidget* find_stack(GtkWidget* w) {
  if (GTK_IS_STACK(w)) {
    return w;
  }
  if (!GTK_IS_CONTAINER(w)) {
    return NULL;
  }
  GList* kids     = gtk_container_get_children(GTK_CONTAINER(w));
  GtkWidget* hit  = NULL;
  for (GList* l = kids; l != NULL && hit == NULL; l = l->next) {
    hit = find_stack(l->data);
  }
  g_list_free(kids);
  return hit;
}

/* built once, the first time a menu opens; styled like the index */
static bool build_menu(void) {
  if (menu != NULL) {
    return true;
  }
  GList* tops = gtk_window_list_toplevels();
  for (GList* l = tops; l != NULL && stack == NULL; l = l->next) {
    if (gtk_widget_get_visible(l->data)) {
      stack = find_stack(l->data);
    }
  }
  g_list_free(tops);
  if (stack == NULL) {
    return false;
  }

  store = gtk_list_store_new(N_COLS, G_TYPE_STRING, G_TYPE_STRING, G_TYPE_STRING, G_TYPE_INT);
  tree  = GTK_TREE_VIEW(gtk_tree_view_new_with_model(GTK_TREE_MODEL(store)));
  g_object_unref(store);
  gtk_style_context_add_class(gtk_widget_get_style_context(GTK_WIDGET(tree)), "indexmode");

  GtkCellRenderer* title = gtk_cell_renderer_text_new();
  GtkCellRenderer* note  = gtk_cell_renderer_text_new();
  g_object_set(title, "ellipsize", PANGO_ELLIPSIZE_MIDDLE, NULL);
  g_object_set(note, "xalign", 1.0, "foreground", "gray", NULL);
  gtk_tree_view_insert_column_with_attributes(tree, 0, "Name", title, "markup", COL_TITLE, NULL);
  gtk_tree_view_insert_column_with_attributes(tree, 1, "Where", note, "text", COL_NOTE, NULL);
  gtk_tree_view_column_set_expand(gtk_tree_view_get_column(tree, 0), TRUE);
  gtk_tree_view_set_headers_visible(tree, FALSE);
  gtk_tree_view_set_enable_search(tree, FALSE);
  g_signal_connect(tree, "key-press-event", G_CALLBACK(on_key), NULL);
  g_signal_connect(tree, "row-activated", G_CALLBACK(on_row_activated), NULL);

  menu = gtk_scrolled_window_new(NULL, NULL);
  gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(menu), GTK_POLICY_AUTOMATIC, GTK_POLICY_AUTOMATIC);
  gtk_container_add(GTK_CONTAINER(menu), GTK_WIDGET(tree));
  gtk_widget_show_all(menu);
  gtk_container_add(GTK_CONTAINER(stack), menu);
  return true;
}

static void open_menu(menu_t which) {
  if (!build_menu()) {
    return;
  }
  if (shown == MENU_NONE) {
    GtkWidget* visible = gtk_stack_get_visible_child(GTK_STACK(stack));
    previous           = visible != menu ? visible : previous;
  }
  shown = which;
  if (which == MENU_BUFFERS) {
    fill_buffers();
  } else {
    g_autofree char* here = current_doc != NULL ? g_path_get_dirname(current_doc) : g_get_current_dir();
    fill_files(here, NULL);
  }
  gtk_stack_set_visible_child(GTK_STACK(stack), menu);
  gtk_widget_grab_focus(GTK_WIDGET(tree));
}

static gboolean on_usr1(gpointer UNUSED(d)) {
  open_menu(MENU_BUFFERS);
  return G_SOURCE_CONTINUE;
}

static gboolean on_usr2(gpointer UNUSED(d)) {
  open_menu(MENU_FILES);
  return G_SOURCE_CONTINUE;
}

/* ---- the window ---- */

static GtkWidget* position; /* "buffer 2/5" in the statusbar */

/* girara's statusbar: an event box of class "statusbar" holding a box of items */
static GtkBox* find_statusbar(GtkWidget* w) {
  if (GTK_IS_EVENT_BOX(w) && gtk_style_context_has_class(gtk_widget_get_style_context(w), "statusbar")) {
    GtkWidget* child = gtk_bin_get_child(GTK_BIN(w));
    if (GTK_IS_BOX(child)) {
      return GTK_BOX(child);
    }
  }
  if (!GTK_IS_CONTAINER(w)) {
    return NULL;
  }
  GList* kids = gtk_container_get_children(GTK_CONTAINER(w));
  GtkBox* hit = NULL;
  for (GList* l = kids; l != NULL && hit == NULL; l = l->next) {
    hit = find_statusbar(l->data);
  }
  g_list_free(kids);
  return hit;
}

/* where the shown document is in zbuf's list, styled like zathura's own items */
static void update_position(void) {
  if (position == NULL) {
    GtkBox* bar = NULL;
    GList* tops = gtk_window_list_toplevels();
    for (GList* l = tops; l != NULL && bar == NULL; l = l->next) {
      bar = find_statusbar(l->data);
    }
    g_list_free(tops);
    if (bar == NULL) {
      return;
    }
    position = gtk_label_new(NULL);
    gtk_widget_set_name(position, "bottom_box");
    gtk_style_context_add_class(gtk_widget_get_style_context(position), "statusbar");
    gtk_widget_set_margin_end(position, 16);
    gtk_box_pack_end(bar, position, FALSE, FALSE, 0);
  }

  int at = 0, count = 0;
  g_autofree char* list = g_build_filename(g_getenv("ZBUF_DIR"), "buffers", NULL);
  g_autofree char* text = NULL;
  g_file_get_contents(list, &text, NULL, NULL);
  g_auto(GStrv) lines = g_strsplit(text != NULL ? text : "", "\n", -1);
  for (char** l = lines; *l != NULL; l++) {
    if (**l != '\0') {
      count++;
      at = g_strcmp0(*l, current_doc) == 0 ? count : at;
    }
  }
  g_autofree char* label = at > 0 ? g_strdup_printf("buffer %d/%d", at, count) : g_strdup("");
  gtk_label_set_text(GTK_LABEL(position), label);
  gtk_widget_set_visible(position, at > 0);
}

static gboolean on_closed(gpointer UNUSED(d)) {
  update_position();
  return G_SOURCE_REMOVE;
}

static gboolean bring_forward(gpointer UNUSED(d)) {
  update_position();
  GList* tops = gtk_window_list_toplevels();
  for (GList* l = tops; l != NULL; l = l->next) {
    if (gtk_widget_get_visible(l->data) && gtk_window_get_window_type(l->data) == GTK_WINDOW_TOPLEVEL) {
      gtk_window_present(l->data);
    }
  }
  g_list_free(tops);
  return G_SOURCE_REMOVE;
}

/* ---- plugin plumbing ---- */

static zathura_plugin_definition_t wrapped; /* the PDF plugin's definition, with our open and free */

static zathura_error_t document_open(zathura_document_t* document) {
  zathura_error_t err = inner_open(document);
  if (err == ZATHURA_ERROR_OK) {
    g_free(current_doc);
    current_doc = g_strdup(zathura_document_get_path(document));
    g_idle_add(bring_forward, NULL);
  }
  return err;
}

static zathura_error_t document_free(zathura_document_t* document, void* data) {
  /* a newer document may already be up when the old one is freed */
  if (g_strcmp0(zathura_document_get_path(document), current_doc) == 0) {
    g_clear_pointer(&current_doc, g_free);
    g_idle_add(on_closed, NULL);
  }
  return inner_free != NULL ? inner_free(document, data) : ZATHURA_ERROR_OK;
}

static bool opens_pdf(const zathura_plugin_definition_t* def) {
  for (size_t i = 0; i < def->mime_types_size; i++) {
    if (g_strcmp0(def->mime_types[i], "application/pdf") == 0) {
      return true;
    }
  }
  return false;
}

/* zathura loads each plugin with g_module_open and fetches its definition with
 * this; hand back our copy for the first plugin that opens PDFs */
static gboolean find_symbol(GModule* module, const gchar* name, gpointer* symbol,
                            gboolean (*real)(GModule*, const gchar*, gpointer*)) {
  if (!real(module, name, symbol)) {
    return FALSE;
  }
  const zathura_plugin_definition_t* def = *symbol;
  if (inner_open == NULL && strcmp(name, G_STRINGIFY(ZATHURA_PLUGIN_DEFINITION_SYMBOL)) == 0 && def != NULL &&
      def->functions.document_open != NULL && opens_pdf(def)) {
    memcpy(&wrapped, def, sizeof(wrapped));
    inner_open                       = def->functions.document_open;
    inner_free                       = def->functions.document_free;
    wrapped.functions.document_open = document_open;
    wrapped.functions.document_free = document_free;
    *symbol                          = &wrapped;
  }
  return TRUE;
}

#ifdef __APPLE__
/* dyld swaps every other image's calls to g_module_symbol for this one */
static gboolean zbuf_g_module_symbol(GModule* module, const gchar* name, gpointer* symbol) {
  return find_symbol(module, name, symbol, g_module_symbol);
}
__attribute__((used, section("__DATA,__interpose"))) static const struct {
  const void* replacement;
  const void* original;
} interpose[] = {{(const void*)zbuf_g_module_symbol, (const void*)g_module_symbol}};
#define PRELOAD_VAR "DYLD_INSERT_LIBRARIES"
#else
/* found before glib's own, since the library is preloaded */
gboolean g_module_symbol(GModule* module, const gchar* name, gpointer* symbol) {
  static gboolean (*real)(GModule*, const gchar*, gpointer*);
  if (real == NULL) {
    real = (gboolean(*)(GModule*, const gchar*, gpointer*))dlsym(RTLD_NEXT, "g_module_symbol");
  }
  return find_symbol(module, name, symbol, real);
}
#define PRELOAD_VAR "LD_PRELOAD"
#endif

__attribute__((constructor)) static void init(void) {
  /* not into zbuf, dbus-send and the rest that zathura runs from here */
  unsetenv(PRELOAD_VAR);
  /* outside zbuf nothing sends the signals, and their default action would kill zathura */
  if (g_getenv("ZBUF_DIR") == NULL) {
    return;
  }
  g_unix_signal_add(SIGUSR1, on_usr1, NULL);
  g_unix_signal_add(SIGUSR2, on_usr2, NULL);
}
