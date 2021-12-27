#pragma once

int getRootCaCerts(void* userData, void (*callback)(void* userData, const unsigned char bytes[], int len));
