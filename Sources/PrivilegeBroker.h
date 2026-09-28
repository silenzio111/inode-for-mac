#pragma once
typedef int (*BrokerSessionRunner)(const char *session_directory, const char *vendor_template);
int privilege_broker_run(const char *directory, const char *parent_text,
                         const char *helper_path, BrokerSessionRunner run_session);
