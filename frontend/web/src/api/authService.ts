import axios from 'axios';

const retrieveApiBaseUrl = (): string => {
    return import.meta.env.VITE_API_URL || 'http://localhost:3000';
};

export const apiClient = axios.create({
    baseURL: retrieveApiBaseUrl(),
    headers: {
        'Content-Type': 'application/json',
    },
});