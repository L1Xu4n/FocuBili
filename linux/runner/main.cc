#include "my_application.h"

int main(int argc, char** argv) {
  g_autoptr(MyApplication) app = my_application_new(argc > 1 && g_strcmp0(argv[1], "web_view_title_bar") == 0);
  return g_application_run(G_APPLICATION(app), argc, argv);
}
