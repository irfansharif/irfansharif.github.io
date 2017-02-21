#!/bin/bash

echo -e "\033[0;32mGenerating blog...\033[0m"
hugo -t=meta --destination=blog
