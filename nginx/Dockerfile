FROM openresty/openresty:alpine

# Create a directory to store Lua scripts
RUN mkdir -p /usr/local/openresty/nginx/lua_scripts

# copy all the files in deploy folder
COPY deploy/ /usr/local/openresty/nginx/lua_scripts

# Copy the nginx configuration file
COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
