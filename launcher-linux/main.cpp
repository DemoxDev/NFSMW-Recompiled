#include "main_window.h"

#include <QApplication>
#include <QCoreApplication>

int main(int argc, char** argv) {
  QApplication application(argc, argv);
  QCoreApplication::setOrganizationName(QStringLiteral("NFSMWRecompiled"));
  QCoreApplication::setApplicationName(QStringLiteral("NfsmwLauncher"));
  QCoreApplication::setApplicationVersion(
      QStringLiteral(NFSMW_LAUNCHER_VERSION));

  nfsmw::launcher::MainWindow window;
  window.show();
  return application.exec();
}
