# Stage 1: Specify the base image. 
# We use nginx:alpine because it's a small, secure, and fast web server.
FROM nginx:alpine

# Copy your custom index.html file into the default Nginx document root.
# Nginx expects to find web files here.
COPY index.html /usr/share/nginx/html/index.html

# Expose the internal port of the container. 
# This port (8080) is what your Nginx reverse proxy will forward traffic to.
# NOTE: This port must match the "Application Internal Port" you input into deploy.sh.
EXPOSE 8080 

# Start Nginx in the foreground (default command for this base image)
CMD ["nginx", "-g", "daemon off;"]
