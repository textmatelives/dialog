// The plug-in listens on a CFMessagePort named <kDialogServerConnectionName>.<pid>, exported to commands as DIALOG_PORT_NAME.
// tm_dialog2 sends one property list per invocation: arguments, environment, cwd and the paths of three FIFOs for stdio.
static NSString* const kDialogServerConnectionName = @"com.macromates.dialog";
