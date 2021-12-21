#pragma once

const int MAX_CERTS = 4096;

int getRootCaCerts(void* userData, void (*callback)(void* userData, const unsigned char bytes[], int length));
